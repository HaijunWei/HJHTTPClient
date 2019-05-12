//
//  HJHTTPClient.m
//
//  Created by Haijun on 2019/5/9.
//

#import "HJHTTPClient.h"
#import "HJHTTPTask+Private.h"
#import "HJHTTPRequestGroup+Private.h"
#import <AFNetworking/AFNetworking.h>

#define HJNetWatingLog(FORMAT, ...) \
    printf("--------------------------------------\n☕️ %s\n\n",    \
    [[NSString stringWithFormat:(FORMAT), ##__VA_ARGS__] UTF8String]);

#define HJNetSuccessLog(FORMAT, ...) \
    printf("--------------------------------------\n🎉 %s\n\n",    \
    [[NSString stringWithFormat:(FORMAT), ##__VA_ARGS__] UTF8String]);

#define HJNetErrorLog(FORMAT, ...) \
    printf("--------------------------------------\n❌ %s\n\n",    \
    [[NSString stringWithFormat:(FORMAT), ##__VA_ARGS__] UTF8String]);

NSErrorDomain const HJHTTPClientDomain = @"com.haijunwei.httpclient";

@interface HJHTTPClient ()

@property (nonatomic, strong) AFHTTPSessionManager *httpManager;
@property (nonatomic, strong) AFHTTPRequestSerializer *httpRequestSerializer;
@property (nonatomic, strong) AFJSONRequestSerializer *jsonRequestSerializer;
@property (nonatomic, strong) NSMutableArray<HJHTTPTask *> *tasks;

@end

@implementation HJHTTPClient

+ (instancetype)shared {
    static id object;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        object = [self new];
    });
    return object;
}

#pragma mark - 单例便利方法

+ (HJHTTPTask *)enqueue:(HJHTTPRequest *)req
                success:(HJHTTPClientSingleSuccessBlock)success
                failure:(HJHTTPClientFailureBlock)failure {
    return [[self shared] enqueue:req success:success failure:failure];
}

+ (HJHTTPTask *)enqueueGroup:(HJHTTPRequestGroup *)group
                     success:(HJHTTPClientSuccessBlock)success
                     failure:(HJHTTPClientFailureBlock)failure {
    return [[self shared] enqueueGroup:group success:success failure:failure];
}

#pragma mark - 发起请求

- (HJHTTPTask *)enqueue:(HJHTTPRequest *)req
                success:(HJHTTPClientSingleSuccessBlock)success
                failure:(HJHTTPClientFailureBlock)failure {
    HJHTTPRequestGroup *group = [HJHTTPRequestGroup new];
    [group add:req];
    return [self enqueueGroup:group success:^(NSArray<HJHTTPResponse *> * _Nonnull reps) {
        if (success) { success(reps.firstObject); }
    } failure:failure];
}

- (HJHTTPTask *)enqueueGroup:(HJHTTPRequestGroup *)group
                     success:(HJHTTPClientSuccessBlock)success
                     failure:(HJHTTPClientFailureBlock)failure {
    HJHTTPTask *httpTask = [HJHTTPTask new];
    httpTask.state = HJHTTPTaskStateNotRunning;
    [self enqueueRequests:group.requests repArray:nil task:httpTask success:success failure:failure];
    [self.tasks addObject:httpTask];
    __weak typeof(self) weakSelf = self;
    httpTask.removeFromContainerBlock = ^(HJHTTPTask * _Nonnull task) {
        [weakSelf.tasks removeObject:task];
    };
    return httpTask;

}

#pragma mark - 核心方法

/// 执行请求，组合响应值
- (void)enqueueRequests:(NSArray *)reqArray
                       repArray:(NSMutableArray *)repArray
                           task:(HJHTTPTask *)task
                        success:(HJHTTPClientSuccessBlock)success
                        failure:(HJHTTPClientFailureBlock)failure {
    NSMutableArray *reqArrayM = [reqArray mutableCopy];
    NSMutableArray *subReqArray = [reqArrayM.firstObject mutableCopy];
    
    for (int i = 0; i < subReqArray.count; i++) {
        // 创建有依赖关系的请求
        if (![subReqArray[i] isKindOfClass:[HJHTTPRequest class]]) {
            HJHTTPRequestLazyAddBlock block = subReqArray[i];
            subReqArray[i] = block(repArray);
        }
    }
    __weak typeof(task) weakTask = task;
    [self enqueueRequests:subReqArray mainTask:task success:^(NSArray *reps) {
        // 拼接所有响应值
        NSMutableArray *resultReps = repArray;
        if (!resultReps) { resultReps = [NSMutableArray new]; }
        [resultReps addObjectsFromArray:reps];
        
        if (reqArrayM.count > 1) {
            // 执行下一组请求
            [reqArrayM removeObjectAtIndex:0];
            [self enqueueRequests:reqArrayM repArray:resultReps task:weakTask success:success failure:failure];
            return;
        }
        weakTask.state = HJHTTPTaskStateNotRunning;
        [weakTask removeFromContainer];
        if (success) { success(resultReps); }
    } failure:^(NSError * _Nonnull error) {
        weakTask.state = HJHTTPTaskStateNotRunning;
        [weakTask removeFromContainer];
        if (failure) { failure(error); }
    }];
}

/// 执行请求集合
- (void)enqueueRequests:(NSArray<HJHTTPRequest *> *)reqs
               mainTask:(HJHTTPTask *)mainTask
                success:(HJHTTPClientSuccessBlock)success
                failure:(HJHTTPClientFailureBlock)failure {
    NSMutableArray *repsArrayM = [NSMutableArray new];
    for (int i = 0; i < reqs.count; i++) {
        [repsArrayM addObject:[NSNull null]];
    }
    __weak typeof(mainTask) weakMainTask = mainTask;
    __block NSError *resultError = nil;
    dispatch_group_t group = dispatch_group_create();
    // 只有一个请求并且是上传文件，可获取进度
    if (reqs.count == 1 && [(HJHTTPRequest *)reqs.firstObject files]) {
        weakMainTask.progress = 0;
        weakMainTask.state = HJHTTPTaskStateProgress;
    } else {
        weakMainTask.state = HJHTTPTaskStateLoading;
    }
    for (int i = 0; i < reqs.count; i++) {
        dispatch_group_enter(group);
        HJHTTPTask *task = [self enqueueRequest:reqs[i] uploadProgress:^(NSProgress *uploadProgress) {
            if (weakMainTask.state == HJHTTPTaskStateProgress) {
                weakMainTask.progress = uploadProgress.fractionCompleted;
            }
        } success:^(id  _Nonnull rep) {
            repsArrayM[i] = rep;
            dispatch_group_leave(group);
        } failure:^(NSError * _Nonnull error) {
            if (!resultError) {
                resultError = error;
                // 一个请求出错，取消全部
                [weakMainTask cancel];
            }
            dispatch_group_leave(group);
        }];
        [weakMainTask addSubtask:task];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        if (resultError) { failure(resultError); }
        else { success(repsArrayM); }
    });
}

/// 执行单个请求
- (HJHTTPTask *)enqueueRequest:(HJHTTPRequest *)req
                uploadProgress:(void(^)(NSProgress *uploadProgress))uploadProgress
                       success:(HJHTTPClientSuccessBlock)success
                       failure:(HJHTTPClientFailureBlock)failure {
    [self willExecuteRequest:req];
    NSMutableURLRequest *urlRequest = [self createURLRequest:req];
    if ([self.delegate respondsToSelector:@selector(httpClient:prepareURLRequest:)]) {
        urlRequest = [self.delegate httpClient:self prepareURLRequest:urlRequest];
    }
    void (^handleCallback)(id response) = ^(id response){
        if ([response isKindOfClass:[NSError class]]) {
            // 网络回调在子线程，错误处理很多时候需要操作UI，切到主线程回调
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *e = [self request:req didError:response];
                failure(e ? : response);
            });
        } else {
            [self request:req didSucess:response];
            success(response);
        }
    };
    NSURLSessionDataTask * task = [self.httpManager dataTaskWithRequest:urlRequest uploadProgress:uploadProgress downloadProgress:nil completionHandler:^(NSURLResponse *response, id responseObject, NSError *error) {
        id resultObject = [self.responseDecoder request:req didGetURLResponse:(NSHTTPURLResponse *)response
                                           responseData:responseObject
                                                  error:error];
        if ([resultObject isKindOfClass:[NSError class]]) {
            handleCallback(resultObject);
        } else {
            NSError *error = [self verifyResponse:resultObject forRequest:req];
            handleCallback(error ? : resultObject);
        }
    }];
    [task resume];
    HJHTTPTask *httpTask = [HJHTTPTask new];
    [httpTask addSubtask:task];
    return httpTask;
}

/// 将要执行请求
- (void)willExecuteRequest:(HJHTTPRequest *)req {
    if (self.isPrintLog) {
        HJNetWatingLog(@"%@，%@，%@", [self methodNameWithRequest:req], req.path, req.params ? : @"{\n}");
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self.delegate respondsToSelector:@selector(httpClient:prepareRequest:)]) {
            [self.delegate httpClient:self prepareRequest:req];
        }
    });
}

/// 请求成功回调
- (void)request:(HJHTTPRequest *)req didSucess:(HJHTTPResponse *)rep {
    if (self.isPrintLog) {
        HJNetSuccessLog(@"%@，%@，%@", [self methodNameWithRequest:req], req.path, rep.data);
    }
    
    
}

/// 验证响应值
- (NSError *)verifyResponse:(HJHTTPResponse *)rep forRequest:(HJHTTPRequest *)req {
    NSString *errorMsg = nil;
    if ([self.delegate respondsToSelector:@selector(httpClient:verifyResponse:forRequest:)]) {
        errorMsg = [self.delegate httpClient:self verifyResponse:rep forRequest:req];
    }
    if (errorMsg) {
        return [NSError errorWithDomain:HJHTTPClientDomain
                                   code:HJHTTPClientErrorCodeVerifyFailure
                               userInfo:@{NSLocalizedDescriptionKey:errorMsg}];
    }
    return nil;
}

/// 请求发生错误
- (NSError *)request:(HJHTTPRequest *)req didError:(NSError *)error {
    if (self.isPrintLog) {
        HJNetErrorLog(@"%@, %@, %@", [self methodNameWithRequest:req], req.path, error.localizedDescription);
    }
    __block NSError *nError = nil;
    if ([self.delegate respondsToSelector:@selector(httpClient:request:didReceiveError:)]) {
        nError = [self.delegate httpClient:self request:req didReceiveError:error];
    }
    return nError;
}

#pragma mark - Helpers

/// 创建请求
- (NSMutableURLRequest *)createURLRequest:(HJHTTPRequest *)request {
    NSError *error;
    NSMutableURLRequest *urlRequest;
    NSString *method = [self methodNameWithRequest:request];
    NSString *urlString = [[NSURL URLWithString:request.path relativeToURL:self.baseURL] absoluteString];
    AFHTTPRequestSerializer *requestSerializer;
    switch (request.contentType) {
        case HJHTTPContentTypeFormData:
            requestSerializer = self.httpRequestSerializer;
            break;
        case HJHTTPContentTypeJSON:
            requestSerializer = self.jsonRequestSerializer;
            break;
    }
    if (request.files) {
        urlRequest = [requestSerializer multipartFormRequestWithMethod:method URLString:urlString parameters:request.params constructingBodyWithBlock:^(id<AFMultipartFormData> formData) {
            for (HJHTTPRequestFormFile *file in request.files) {
                [formData appendPartWithFileData:file.data name:file.name fileName:file.fileName mimeType:file.mineType];
            }
        } error:&error];
    } else {
        urlRequest = [requestSerializer requestWithMethod:method URLString:urlString parameters:request.params error:&error];
    }
    NSAssert(error == nil, @"创建请求失败");
    if (request.timeoutInterval > 0) {
        urlRequest.timeoutInterval = request.timeoutInterval;
    } else {
        urlRequest.timeoutInterval = self.timeoutInterval;
    }
    return urlRequest;
}

/// 获取指定Requet请求方式名称
- (NSString *)methodNameWithRequest:(HJHTTPRequest *)request {
    switch (request.method) {
        case HJHTTPMethodGET: return @"GET";
        case HJHTTPMethodPOST: return @"POST";
        case HJHTTPMethodPUT: return @"PUT";
        case HJHTTPMethodDELETE: return @"DELETE";
    }
}

#pragma mark - Init

- (instancetype)init {
    if (self = [super init]) {
        _isPrintLog = YES;
        _timeoutInterval = 15;
        _tasks = [NSMutableArray new];
        _httpManager = [AFHTTPSessionManager manager];
        _httpManager.responseSerializer = [AFHTTPResponseSerializer serializer];
        _httpManager.completionQueue = dispatch_get_global_queue(0, 0);
    }
    return self;
}

#pragma mark - Getter

- (AFHTTPRequestSerializer *)httpRequestSerializer {
    if (!_httpRequestSerializer) {
        _httpRequestSerializer = [AFHTTPRequestSerializer new];
    }
    return _httpRequestSerializer;
}

- (AFJSONRequestSerializer *)jsonRequestSerializer {
    if (!_jsonRequestSerializer) {
        _jsonRequestSerializer = [AFJSONRequestSerializer new];
    }
    return _jsonRequestSerializer;
}

@end
