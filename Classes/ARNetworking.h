//
//  ARNetworking.h
//  AipaiReconsitution
//
//  Created by Dean.Yang on 2017/6/27.
//  Copyright © 2017年 Dean.Yang. All rights reserved.
//

#import <Foundation/Foundation.h>

@class ARNetworking;
@class ARNetworkingDataTask;
@class ARNetworkingDownloadTask;

typedef void(^ARNetworkDidReceiveResponseCallback)(NSHTTPURLResponse *httpURLResponse);
typedef void(^ARNetworkProgressCallback)(NSProgress *progress);
typedef void(^ARNetworkCompletionHandler)(NSError *error,id responseObj);

@interface ARNetworking : NSObject

+ (void)setUserAgent:(NSString *)userAgent;

@property (nonatomic, strong, readonly) NSURLRequest *request;
@property (nonatomic, strong, readonly) NSHTTPURLResponse *httpURLResponse;

/** 设置超时时间，默认是15s [resume]前有效 */
@property (nonatomic, assign) NSTimeInterval timeoutInterval;
/** 设置请求头 [resume]前有效 */
@property (nonatomic, strong, readonly) NSMutableDictionary *headers;
/** 设置请求参数 [resume]前有效 */
@property (nonatomic, strong) id parameters;

/** 请求接收到响应 */
@property (nonatomic, copy) ARNetworkDidReceiveResponseCallback didReceiveResponseCallback;
/** 下载是接收Data进度回调 */
@property (nonatomic, copy) ARNetworkProgressCallback downloadProgressCallback;
/** 请求完成回调 */
@property (nonatomic, copy) ARNetworkCompletionHandler completionHandler;

/** 完成后回调队列 */
@property (nonatomic, strong) dispatch_queue_t completionQueue;

/**
 自定义请求方式
 OPTIONS,HEAD,GET,POST,PUT,DELETE,CONNECT
 */
- (instancetype)initWithMethod:(NSString *)method
                           url:(NSString *)url
                    parameters:(id)parameters
             completionHandler:(ARNetworkCompletionHandler)completionHandler;

/**
 GET
 */
+ (ARNetworking *)GETWithUrl:(NSString *)url
                  parameters:(id)parameters
           completionHandler:(ARNetworkCompletionHandler)completionHandler;

/**
 POST
 */
+ (ARNetworking *)POSTWithUrl:(NSString *)url
                   parameters:(id)parameters
            completionHandler:(ARNetworkCompletionHandler)completionHandler;

/**
 Download
 */
+ (ARNetworking *)DownloadWithUrl:(NSString *)url
                      destination:(NSString *)destinationPath
                           offset:(NSUInteger)offset
                completionHandler:(ARNetworkCompletionHandler)completionHandler;

- (void)resume;
- (void)cancel;

@end





