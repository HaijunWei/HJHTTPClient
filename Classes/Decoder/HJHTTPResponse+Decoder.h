//
//  HJHTTPResponse+Decoder.h
//
//  Created by Haijun on 2019/5/9.
//

#import "HJHTTPResponse.h"

NS_ASSUME_NONNULL_BEGIN

@interface HJHTTPResponse (Decoder)

/// 反序列化后的对象
@property (nonatomic, strong) id dataObject;

@end

NS_ASSUME_NONNULL_END
