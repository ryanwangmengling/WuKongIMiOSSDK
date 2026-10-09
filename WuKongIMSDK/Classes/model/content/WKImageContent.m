//
//  WKImageMessageContent.m
//  WuKongIMSDK
//
//  Created by tt on 2020/1/13.
//

#import "WKImageContent.h"
#import "WKConst.h"
#import "WKMediaUtil.h"
#import "WKFileUtil.h"
#import "WKSDK.h"
#import "WKImageUtil.h"
#import "WKMOSContentConvertManager.h"
@interface WKImageContent ()
@property(nonatomic,strong) UIImage  *orgImage;

@property(nonatomic,strong) NSData *data;

@property(nonatomic,strong) NSData *thumbData;

@property(nonatomic,copy) NSString *_localPath; // 本地路径
@end

@implementation WKImageContent

+ (instancetype)initWithImage:(UIImage *)image {
    WKImageContent *content = [WKImageContent new];
    content.width = image.size.width;
    content.height = image.size.height;
    content.orgImage = image;
    return content;
}


+ (instancetype)initWithData:(NSData *)data width:(CGFloat)width height:(CGFloat)height {
   
    return [self initWithData:data width:width height:height thumbData:nil];
}

+ (instancetype)initWithData:(NSData *)data width:(CGFloat)width height:(CGFloat)height thumbData:(NSData*)thumbData {
    WKImageContent *content = [WKImageContent new];
    content.data = data;
    content.width = width;
    content.height = height;
    content.thumbData = thumbData;
    return content;
}

- (UIImage *)originalImage {
    if(!self.orgImage) {
        self.orgImage = [UIImage imageWithContentsOfFile:[self localPath]];
    }
    return self.orgImage;
}

- (NSData *)originalImageData {
    return [[NSData alloc] initWithContentsOfFile:[self localPath]];
}



-(UIImage*) thumbnailImage {
    if(!_thumbnailImage) {
        // 修复(OOM)：原实现 [UIImage imageWithContentsOfFile:] 按文件里的原始分辨率整图解码，
        // 缩略图文件异常偏大时会顶高内存峰值。改为按最大边长降采样解码
        // （对应 Android BitmapFactory.Options.inSampleSize 采样解码）。
        _thumbnailImage = [WKImageUtil downsampleImageWithFile:[self thumbPath]
                                                  maxPixelSize:[WKImageUtil defaultMaxPixelSize]];
        if(!_thumbnailImage) {
            // 极少数格式（ImageIO 解不了）退回原逻辑，保证可用性
            _thumbnailImage = [UIImage imageWithContentsOfFile:[self thumbPath]];
        }
    }
    return _thumbnailImage;
}

- (NSData *)thumbnailData {
    return [[NSData alloc] initWithContentsOfFile:[self thumbPath]];
}

- (NSString *)extension {
    return @"";
}

- (void) writeDataToLocalPath {
    [super writeDataToLocalPath];
    // 获取本地路径
   if(self.orgImage) {
       self.width = self.orgImage.size.width;
       self.height = self.orgImage.size.height;
       
        NSData *thumdData = [WKImageUtil compressImage:self.orgImage toMaxBytes:[WKSDK shared].options.imageMaxBytes];
       if(thumdData) {
           [thumdData writeToFile:self.thumbPath atomically:YES];
       }
       
       [UIImagePNGRepresentation(self.orgImage) writeToFile:self.localPath atomically:YES];
    }
    if(self.data) {
        if(self.thumbData) {
             [self.thumbData writeToFile:self.thumbPath atomically:YES];
        }else {
            // 修复(OOM)：原实现 [UIImage imageWithData:self.data] 会按原分辨率整图解码，
            // 相机原图（几十 MB 位图）在发送时会直接顶爆内存。
            // 改为 ImageIO 采样解码 + 质量压缩，峰值内存由 WKImageUtil.defaultMaxPixelSize 决定
            // （对应 Android BitmapFactory.Options.inSampleSize 的图片 OOM 修复 9c7878d/151e946）。
            NSData *thumbData = [WKImageUtil compressImageData:self.data toMaxBytes:[WKSDK shared].options.imageMaxBytes];
            if(thumbData) {
                [thumbData writeToFile:self.thumbPath atomically:YES];
            }
        }
        // 调用方没有给出尺寸时，只读取像素尺寸（不解码整图，对应 Android inJustDecodeBounds）
        if(self.width <= 0 || self.height <= 0) {
            CGSize size = [WKImageUtil imageSizeWithData:self.data];
            if(size.width > 0 && size.height > 0) {
                self.width = size.width;
                self.height = size.height;
            }
        }
       
        [self.data writeToFile:self.localPath atomically:YES];
    }
}

- (void)decodeWithJSON:(NSDictionary *)contentDic {
    self.remoteUrl = contentDic[@"url"];
    self.width = contentDic[@"width"]?[contentDic[@"width"] floatValue]:0;
    self.height = contentDic[@"height"]?[contentDic[@"height"] floatValue]:0;
}

- (NSDictionary *)encodeWithJSON {
    NSMutableDictionary *dataDict = [NSMutableDictionary dictionary];
    [dataDict setObject:self.remoteUrl?:@"" forKey:@"url"];
    [dataDict setObject:@(self.width) forKey:@"width"];
    [dataDict setObject:@(self.height) forKey:@"height"];
    return dataDict;
}

+(NSNumber*) contentType {
    return @(WK_IMAGE);
}

- (NSString *)conversationDigest {
    return @"[图片]";
}

- (NSString *)searchableWord {
    return @"[图片]";
}

- (BOOL)viewedOfVisible {
    if(self.message && self.message.isSend) {
        return true;
    }
    return false;
}

-(void) releaseData {
    self.orgImage = nil;
    self.thumbnailImage = nil;
    self.thumbData = nil;
    self.data = nil;
}
@end
