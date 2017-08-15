//
//  ARNetworking.m
//  AipaiReconsitution
//
//  Created by Dean.Yang on 2017/6/27.
//  Copyright © 2017年 Dean.Yang. All rights reserved.
//

#import "ARNetworking.h"
#import <objc/runtime.h>

#pragma mark -  AFHTTPSessionManagerCategory

static NSString *const sessionDescription = @"arnetworking_session";

typedef void(^ARDataTaskDidReceiveDataBlock)(NSURLSession *session,NSURLSessionDataTask *dataTask,NSData *data);

@interface AFHTTPSessionManager(ARNetworking)
@property (nonatomic, copy) ARDataTaskDidReceiveDataBlock ar_dataTaskDidReceiveDataBlock;
@end

@implementation AFHTTPSessionManager(ARNetworking)

static const char ARDataTaskDidReceiveDataBlockKey;

- (void)ar_URLSession:(NSURLSession *)session
             dataTask:(NSURLSessionDataTask *)dataTask
       didReceiveData:(NSData *)data {
    
    if ([self.session.sessionDescription isEqualToString:sessionDescription] && self.ar_dataTaskDidReceiveDataBlock) {
        self.ar_dataTaskDidReceiveDataBlock(session, dataTask, data);
    } else {
        [self ar_URLSession:session dataTask:dataTask didReceiveData:data];
    }
}

- (void)setAr_dataTaskDidReceiveDataBlock:(ARDataTaskDidReceiveDataBlock)ar_dataTaskDidReceiveDataBlock {
    objc_setAssociatedObject(self, &ARDataTaskDidReceiveDataBlockKey, ar_dataTaskDidReceiveDataBlock, OBJC_ASSOCIATION_COPY);
}

- (ARDataTaskDidReceiveDataBlock)ar_dataTaskDidReceiveDataBlock {
    return (ARDataTaskDidReceiveDataBlock)objc_getAssociatedObject(self, &ARDataTaskDidReceiveDataBlockKey);
}

@end

#pragma mark - ARNetworkingCategory

@interface ARNetworking(Ext)
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, strong) NSHTTPURLResponse *httpURLResponse;
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error;
@end

#pragma mark - ARNetworkingDataTask

@interface ARNetworkingDataTask : ARNetworking
@property (nonatomic, strong) NSURLSessionDataTask *sessionDataTask;
@property (nonatomic, strong) NSProgress *progress;
@property (nonatomic, assign) unsigned long long totalBytesRead;
- (NSURLSessionResponseDisposition)URLSession:(NSURLSession *)session
                                     dataTask:(NSURLSessionDataTask *)dataTask
                           didReceiveResponse:(NSURLResponse *)response;
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data;
@end

@implementation ARNetworkingDataTask

- (void)resume {
    [super resume];
    
    __weak typeof(self) weakSelf = self;
    self.sessionDataTask = [self.sessionManager dataTaskWithRequest:self.request completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                self.httpURLResponse = (NSHTTPURLResponse *)response;
            }
            if (self.completionHandler) {
                self.completionHandler(error, responseObject);
            }
        }
    }];
    
    [self.sessionManager setDataTaskDidReceiveResponseBlock:^NSURLSessionResponseDisposition(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSURLResponse * _Nonnull response) {
        __strong typeof(weakSelf) self = weakSelf;
        return [self URLSession:session dataTask:dataTask didReceiveResponse:response];
    }];
    
    [self.sessionManager setDataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
        __strong typeof(weakSelf) self = weakSelf;
        [self URLSession:session dataTask:dataTask didReceiveData:data];
    }];
    
    [self.sessionDataTask resume];
}

- (void)cancel {
    [super cancel];
    [self.sessionDataTask cancel];
}

- (NSURLSessionResponseDisposition)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response {
    self.httpURLResponse = (NSHTTPURLResponse *)response;
    self.progress = [NSProgress progressWithTotalUnitCount:0];
    self.progress.completedUnitCount = self.httpURLResponse.expectedContentLength;
    return NSURLSessionResponseAllow;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    self.totalBytesRead += (long long)data.length;
    self.progress.totalUnitCount = self.totalBytesRead;
    __weak typeof(self) wself = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (wself.downloadProgressCallback) {
            wself.downloadProgressCallback(wself.progress);
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
// @property (nonatomic, strong) NSURLSessionDownloadTask *sessionDownloadTask;
@property (nonatomic, strong) NSString *destinationPath;
@property (nonatomic, strong) NSOutputStream *outputStream;
@property (nonatomic, assign) NSUInteger offset;
@end

@implementation ARNetworkingDownloadTask

+ (void)load {
    Method orignialMethod = class_getInstanceMethod([AFURLSessionManager class],@selector(URLSession:dataTask:didReceiveData:));
    Method swappedMethod = class_getInstanceMethod([AFURLSessionManager class], @selector(ar_URLSession:dataTask:didReceiveData:));
    method_exchangeImplementations(orignialMethod, swappedMethod);
}

- (void)dealloc {
    
    self.sessionManager.dataTaskDidReceiveDataBlock = nil;
    
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
    
    self.totalBytesRead = 0;
    self.outputStream = [NSOutputStream outputStreamToFileAtPath:self.destinationPath append:YES];
    
    __weak typeof(self) weakSelf = self;
    [self.sessionManager setAr_dataTaskDidReceiveDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionDataTask * _Nonnull dataTask, NSData * _Nonnull data) {
        __strong typeof(weakSelf) self = weakSelf;
        [self URLSession:session dataTask:dataTask didReceiveData:data];
    }];
    
    [super resume];
}

- (void)cancel {
    [super cancel];
}

- (NSURLSessionResponseDisposition)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response {
    
    if (((NSHTTPURLResponse *)response).statusCode == 206) {
        [self.outputStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        [self.outputStream open];
    }
    
    return [super URLSession:session dataTask:dataTask didReceiveResponse:response];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    
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
            if (self.outputStream.streamError) {
                if (self.completionHandler) {
                    self.completionHandler(self.outputStream.streamError, nil);
                }
            }
            return;
        }
    }
    
    [super URLSession:session dataTask:dataTask didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    [self.outputStream close];
    [self setOutputStream:nil];
    [super URLSession:session task:task didCompleteWithError:error];
}

@end

#pragma mark - ARNetworkingUploadTask

@interface ARNetworkingUploadTask : ARNetworking
@property (nonatomic, strong) NSURLSessionUploadTask *sessionUploadTask;
@property (nonatomic, copy) NSString *fileUrl;
@property (nonatomic, strong) NSString *paramName;
@property (nonatomic, strong) NSProgress *progress;
@end

@implementation ARNetworkingUploadTask

+ (ARNetworking *)UploadWithUrl:(NSString *)url fromFile:(NSString *)fileUrl paramName:(NSString *)paramName completionHandler:(ARNetworkCompletionHandler)completionHandler {
    ARNetworkingUploadTask *networkingUploadTask = [[ARNetworkingUploadTask alloc] init];
    networkingUploadTask.fileUrl = fileUrl;
    networkingUploadTask.paramName = paramName;
    networkingUploadTask.completionHandler = completionHandler;
    
    NSMutableURLRequest *request = [[AFHTTPRequestSerializer serializer] multipartFormRequestWithMethod:@"POST" URLString:url parameters:nil constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
        [formData appendPartWithFileData:[NSData dataWithContentsOfFile:fileUrl] name:paramName fileName:fileUrl.lastPathComponent mimeType:@"text/plain"];
    } error:nil];
    [request setHTTPMethod:@"POST"];
    networkingUploadTask.request = [request copy];
    
    return networkingUploadTask;
}

- (void)resume {
    [super resume];
    
    __weak typeof(self) weakSelf = self;
    self.sessionUploadTask = [self.sessionManager uploadTaskWithStreamedRequest:self.request progress:nil completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self) {
            if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                self.httpURLResponse = (NSHTTPURLResponse *)response;
            }
            if (self.completionHandler) {
                self.completionHandler(error, responseObject);
            }
        }
    }];
    
    [self.sessionManager setTaskDidSendBodyDataBlock:^(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, int64_t bytesSent, int64_t totalBytesSent, int64_t totalBytesExpectedToSend) {
        __strong typeof(weakSelf) self = weakSelf;
        self.progress.totalUnitCount = totalBytesSent;
        self.progress.completedUnitCount = totalBytesExpectedToSend;
        if (self.uploadProgressCallback) {
            self.uploadProgressCallback(self.progress);
        }
    }];
    
    self.progress = [self.sessionManager uploadProgressForTask:self.sessionUploadTask];
    
    [self.sessionUploadTask resume];
}

- (void)cancel {
    [super cancel];
    [self.sessionUploadTask cancel];
}

@end

#pragma mark - ARNetworking

@interface ARNetworking()
@property (nonatomic, strong) AFHTTPSessionManager *sessionManager;
@property (nonatomic, strong) NSMutableDictionary *headers;
@end

@implementation ARNetworking {
    os_block_t _resumeCancel;
    BOOL _isResumed;
    BOOL _isCancelled;
}

- (instancetype)init {
    if (self = [super init]) {
        self.sessionManager = [AFHTTPSessionManager manager];
        self.sessionManager.responseSerializer.acceptableContentTypes = [NSSet setWithObjects:@"application/json", @"text/json", @"text/javascript", @"text/html", @"text/plain",nil];
        self.sessionManager.session.sessionDescription = sessionDescription;
        
        self.timeoutInterval = 15.0f;
        self.shouldUseCookie = YES;
        
        _isResumed = NO;
        _isCancelled = NO;
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
    return [ARNetworkingDownloadTask DownloadWithUrl:url destination:destinationPath offset:offset completionHandler:completionHandler];
}

+ (ARNetworking *)UploadWithUrl:(NSString *)url fromFile:(NSString *)fileUrl paramName:(NSString *)paramName completionHandler:(ARNetworkCompletionHandler)completionHandler {
    return [ARNetworkingUploadTask UploadWithUrl:url fromFile:fileUrl paramName:paramName completionHandler:completionHandler];
}

#pragma mark - public instance method

- (void)resume {
    
    if (_isResumed) {
        //        [[NSException exceptionWithName:@"ARNetworkException"
        //                                 reason:@"Network is resumed"
        //                               userInfo:nil] raise];
        [self cancel];
    }
    
    _isResumed = YES;
    _isCancelled = NO;
    
    NSMutableURLRequest *req = [self.request mutableCopy];
    req.timeoutInterval = self.timeoutInterval;
    req.HTTPShouldHandleCookies = self.shouldUseCookie;
    for (NSString *key in self.headers.allKeys) {
        [req setValue:self.headers[key] forHTTPHeaderField:key];
    }
    
    self.request = [self.sessionManager.requestSerializer requestBySerializingRequest:req withParameters:self.parameters error:nil];
    
    __strong __block ARNetworking *strongSelf = self;
    _resumeCancel = ^{
        strongSelf = nil;
    };
    [self.sessionManager setTaskDidCompleteBlock:^(NSURLSession * _Nonnull session, NSURLSessionTask * _Nonnull task, NSError * _Nullable error) {
        [strongSelf.sessionManager.session finishTasksAndInvalidate];
        [strongSelf URLSession:session task:task didCompleteWithError:error];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            strongSelf = nil;
        });
    }];
}

- (void)cancel {
    if (_isCancelled) {
        return;
    }
    
    _resumeCancel ? _resumeCancel() : nil;
    [self.sessionManager.operationQueue cancelAllOperations];
    [self.sessionManager.session invalidateAndCancel];
    _isCancelled = YES;
    _isResumed = NO;
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

#pragma mark - private method

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    ;
}

// !!!: 验证https证书

@end


