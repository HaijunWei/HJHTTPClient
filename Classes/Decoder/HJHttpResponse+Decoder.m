//
//  HJHttpResponse+Decoder.m
//
//  Created by Haijun on 2019/5/9.
//

#import "HJHttpResponse+Decoder.h"

static NSString * const kDataObject = @"dataObject";

@implementation HJHttpResponse (Decoder)

- (void)setDataObject:(id)dataObject {
    self.userInfo[kDataObject] = dataObject;
}

- (id)dataObject {
    return self.userInfo[kDataObject];
}

@end
