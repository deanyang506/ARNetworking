//
//  ARNetworking.m
//  AipaiReconsitution
//
//  Created by Dean.Yang on 2017/6/27.
//  Copyright © 2017年 Dean.Yang. All rights reserved.
//

#import "ARNetworking.h"
#import <AFNetworking/AFHTTPSessionManager.h>
#import <AFNetworking/AFURLSessionManager.h>
#import <objc/runtime.h>

#pragma mark -  AFHTTPSessionManagerCategory

@protocol ARNetworkingTaskDelegate <NSObject>
@required
- (void)dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data;
- (NSURLSessionResponseDisposition *)dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response;
- (void)task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error responseObject:(id)responseObject;
@end

@interface NSURLSessionTaskProxy : NSObject
@property (nonatomic, weak) id<ARNetworkingTaskDelegate> delegate;
@end
@implementation NSURLSessionTaskProxy
@end

@interface NSURLSessionTask(ARNetworking)
@property (nonatomic, strong) NSURLSessionTaskProxy *proxy;
@end

@implementation NSURLSessionTask(ARNetworking)

static const char ARNetworkingTaskProxKey;
- (NSURLSessionTaskProxy *)proxy {
    NSURLSessionTaskProxy *proxy = nil;
    @synchronized (self) {
        proxy = (NSURLSessionTaskProxy *)objc_getAssociatedObject(self, &ARNetworkingTaskProxKey);
        if (proxy == nil) {
            proxy = [[NSURLSessionTaskProxy alloc] init];
            objc_setAssociatedObject(self, &ARNetworkingTaskProxKey, proxy, OBJC_ASSOCIATION_RETAIN);
        }
    }
    return proxy;
}
@end

@interface AFHTTPSessionManager(ARNetworking)
- (NSObject *)delegateForTask:(NSURLSessionTask *)task;
@end
@implementation AFHTTPSessionManager(ARNetworking)
@end

#pragma mark - ARNetworkingCategory

@interface ARNetworking(Ext) <ARNetworkingTaskDelegate>
@property (nonatomic, strong) NSHTTPURLResponse *httpURLResponse;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSURLSessionDataTask *sessionDataTask;
@end

#pragma mark - ARNetworkingDataTask

@interface ARNetworkingDataTask : ARNetworking
@property (nonatomic, strong) NSProgress *progress;
@property (nonatomic, assign) unsigned long long completedBytesRead;
@end

@implementation ARNetworkingDataTask

- (void)resume {
    self.completedBytesRead = 0;
    [super resume];
}

- (NSURLSessionResponseDisposition *)dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response {
    NSURLSessionResponseDisposition *disposition = [super dataTask:dataTask didReceiveResponse:response];
    self.progress = [NSProgress progressWithTotalUnitCount:0];
    self.progress.totalUnitCount = self.httpURLResponse.expectedContentLength;
    return disposition;
}

- (void)dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    self.completedBytesRead += (long long)data.length;
    self.progress.completedUnitCount = self.completedBytesRead;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.downloadProgressCallback) {
            self.downloadProgressCallback(self.progress);
        }
    });
}

@end

#pragma mark - ARNetworkingDownloadTask

@interface ARNetworkingDownloadTask : ARNetworkingDataTask
/**
 这里不用DownloadTask的原因：
 1、不知道系统现在的临时目录文件名，只有完成的时候才知道
 2、不能中途知道具体下载的data, 因为是直接保存到了临时文件
 3、如果用户kill程序，就没办法保存到resumeData, iOS8及以上可以用backgroundSessionConfigurationWithIdentifier
 4、如果保存不到resumeData就没办法断点续传
 5、kill掉的程序临时目录不定时会被删除
 6、只有下载完成的时候才能将文件转移到destinationPath，此间是没有该文件的，对于调用改类的业务很不好控制
 */
@property (nonatomic, strong) NSString *destinationPath;
@property (nonatomic, assign) NSUInteger offset;
@property (nonatomic, strong) NSOutputStream *outputStream;
@end

@implementation ARNetworkingDownloadTask

- (void)dealloc {
    if (_outputStream) {
        [_outputStream close];
        _outputStream = nil;
    }
}

+ (ARNetworking *)DownloadWithUrl:(NSString *)url destination:(NSString *)destinationPath offset:(NSUInteger)offset completionHandler:(ARNetworkCompletionHandler)completionHandler {
    ARNetworkingDownloadTask *networkingDownloadTask = [[ARNetworkingDownloadTask alloc] initWithMethod:@"GET" url:url parameters:nil completionHandler:completionHandler];
    networkingDownloadTask.destinationPath = destinationPath;
    networkingDownloadTask.offset = offset;
    return networkingDownloadTask;
}

- (void)resume {
    [self.headers setValue:[NSString stringWithFormat:@"bytes=%lu-",self.offset] forKey:@"Range"];
    self.outputStream = [NSOutputStream outputStreamToFileAtPath:self.destinationPath append:YES];
    
    [super resume];
    
    if ([self.sessionManager respondsToSelector:@selector(delegateForTask:)]) {
        NSObject *delegate = [self.sessionManager delegateForTask:self.sessionDataTask];
        if ([(NSStringFromClass(delegate.class)) isEqualToString:@"AFURLSessionManagerTaskDelegate"]) {
            //将AFURLSessionManagerTaskDelegate的属性字段mutableData置空是因为每次下载datatask每次接收到数据会被存起来，如果是下载文件内存将暴增
            [delegate setValue:nil forKeyPath:@"mutableData"];
        }
    }
}

- (NSURLSessionResponseDisposition *)dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response {
    if (((NSHTTPURLResponse *)response).statusCode == 206) {
        [self.outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [self.outputStream open];
    }
    
    return [super dataTask:dataTask didReceiveResponse:response];
}

- (void)dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data  {
    
    NSUInteger length = [data length];
    while (YES) {
        NSInteger totalNumberOfBytesWritten = 0;
        if ([self.outputStream hasSpaceAvailable]) {
            const uint8_t *dataBuffer = (uint8_t *)[data bytes];
            
            NSInteger numberOfBytesWritten = 0;
            while (totalNumberOfBytesWritten < (NSInteger)length) {
                numberOfBytesWritten = [self.outputStream write:&dataBuffer[(NSUInteger)totalNumberOfBytesWritten] maxLength:(length - (NSUInteger)totalNumberOfBytesWritten)];
                if (numberOfBytesWritten == -1) {
                    break;
                }
                
                totalNumberOfBytesWritten += numberOfBytesWritten;
            }
            
            break;
        } else {
            [self cancel];
            [self task:self.sessionDataTask didCompleteWithError:self.outputStream.streamError ?: [NSError errorWithDomain:NSStringFromClass(self.class) code:-1 userInfo:@{NSLocalizedDescriptionKey:@"hasnotSpaceAvailable"}] responseObject:nil];
            return;
        }
    }
    
    [super dataTask:dataTask didReceiveData:data];
}

- (void)task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error responseObject:(id)responseObject {
    [self.outputStream close];
    [self setOutputStream:nil];
    [super task:task didCompleteWithError:error responseObject:responseObject];
}

@end

#pragma mark - ARNetworking

@interface ARNetworking()
@property (nonatomic, strong) ARNetworking *strongSelf;
@property (nonatomic, strong) NSMutableDictionary *headers;
@property (nonatomic, strong) NSURLSessionDataTask *sessionDataTask;
@end

@implementation ARNetworking

- (void)dealloc {
    NSLog(@"[ARNetworking]dealloc");
}

#pragma mark -

static NSString *UserAgent = nil;
+ (void)setUserAgent:(NSString *)userAgent {
    UserAgent = userAgent;
}

- (AFHTTPSessionManager *)sessionManager {
    static AFHTTPSessionManager *_sessionManager;
    static dispatch_queue_t arnet_completion_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sessionManager = [AFHTTPSessionManager manager];
        _sessionManager.securityPolicy.allowInvalidCertificates = YES;
        _sessionManager.securityPolicy.validatesDomainName = NO;
        _sessionManager.responseSerializer.acceptableContentTypes = [NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", @"text/html", @"text/plain", @"application/javascript", @"application/octet-stream", nil];
        [_sessionManager setDataTaskDidReceiveResponseBlock:^NSURLSessionResponseDisposition(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSURLResponse * _Nonnull response) {
            return [dataTask.proxy.delegate dataTask:dataTask didReceiveResponse:response];
        }];
        [_sessionManager setDataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
            [dataTask.proxy.delegate dataTask:dataTask didReceiveData:data];
        }];
        arnet_completion_queue = dispatch_queue_create("com.arnetworking", DISPATCH_QUEUE_CONCURRENT);
        _sessionManager.completionQueue = arnet_completion_queue;
    });
    return _sessionManager;
}

- (instancetype)init {
    if (self = [super init]) {
        _timeoutInterval = 15.0f;
    }
    return self;
}

- (instancetype)initWithMethod:(NSString *)method
                           url:(NSString *)url
                    parameters:(id)parameters
             completionHandler:(ARNetworkCompletionHandler)completionHandler {
    if (self = [self init]) {
        NSError *error = nil;
        NSMutableURLRequest *request = [self.sessionManager.requestSerializer requestWithMethod:method URLString:url parameters:nil error:&error];
        if (error || request == nil) {
            request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
            [request setHTTPMethod:method];
            request = [[self.sessionManager.requestSerializer requestBySerializingRequest:request withParameters:nil error:nil] mutableCopy];
        }
        
        self.request = [request copy];
        self.parameters = parameters;
        self.completionHandler = completionHandler;
    }
    
    return self;
}

#pragma mark - public initial method

+ (ARNetworking *)GETWithUrl:(NSString *)url parameters:(id)parameters completionHandler:(ARNetworkCompletionHandler)completionHandler {
    ARNetworking *networking = [[ARNetworkingDataTask alloc] initWithMethod:@"GET" url:url parameters:parameters completionHandler:completionHandler];
    return networking;
}

+ (ARNetworking *)POSTWithUrl:(NSString *)url parameters:(id)parameters completionHandler:(ARNetworkCompletionHandler)completionHandler {
    ARNetworking *networking = [[ARNetworkingDataTask alloc] initWithMethod:@"POST" url:url parameters:parameters completionHandler:completionHandler];
    return networking;
}

+ (ARNetworking *)DownloadWithUrl:(NSString *)url destination:(NSString *)destinationPath offset:(NSUInteger)offset completionHandler:(ARNetworkCompletionHandler)completionHandler {
    ARNetworking *downloadNetworking = [ARNetworkingDownloadTask DownloadWithUrl:url destination:destinationPath offset:offset completionHandler:completionHandler];
    return downloadNetworking;
}

#pragma mark - public instance method

- (void)resume {
    self.strongSelf = self;
    
    NSMutableURLRequest *req = [self.request mutableCopy];
    req.timeoutInterval = _timeoutInterval;
    req.HTTPShouldHandleCookies = YES;
    for (NSString *key in self.headers.allKeys) {
        [req setValue:self.headers[key] forHTTPHeaderField:key];
    }
    if (UserAgent) {
        [req setValue:UserAgent forHTTPHeaderField:@"User-Agent"];
    }
    self.request = [self.sessionManager.requestSerializer requestBySerializingRequest:req withParameters:self.parameters error:nil];
    
    __weak typeof(self) weakSelf = self;
    self.sessionDataTask = [self.sessionManager dataTaskWithRequest:self.request uploadProgress:nil downloadProgress:nil completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        [self task:self.sessionDataTask didCompleteWithError:error responseObject:responseObject];
    }];
    self.sessionDataTask.proxy.delegate = self;
    [self.sessionDataTask resume];
}

- (void)cancel {
    [self.sessionDataTask cancel];
}

#pragma mark - setter

- (void)setRequest:(NSURLRequest *)request {
    _request = request;
}

- (void)setHttpURLResponse:(NSHTTPURLResponse *)httpURLResponse {
    _httpURLResponse = httpURLResponse;
}

#pragma mark - getter

- (NSMutableDictionary *)headers {
    if (!_headers) {
        _headers = [NSMutableDictionary dictionary];
    }
    return _headers;
}

#pragma mark - ARNetworkingTaskDelegate

- (NSURLSessionResponseDisposition *)dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response {
    self.httpURLResponse = (NSHTTPURLResponse *)response;
    if (self.didReceiveResponseCallback) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didReceiveResponseCallback(self.httpURLResponse);
        });
    }
    return NSURLSessionResponseAllow;
}

- (void)dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {}

- (void)task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error responseObject:(id)responseObject {
    if ([task.response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.httpURLResponse = (NSHTTPURLResponse *)task.response;
    }
    if (self.completionHandler) {
        dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{
            self.completionHandler(error, responseObject);
        });
    }
    self.strongSelf = nil;
}

@end



