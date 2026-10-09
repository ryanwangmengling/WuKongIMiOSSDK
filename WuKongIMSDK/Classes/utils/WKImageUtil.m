//
//  WKImageUtil.m
//  WuKongIMSDK
//
//  移植来源：WuKongIMAndroidSDK 图片 OOM 修复
//    - 9c7878d / 151e946「改进图片尺寸获取方式防止OOM，使用 BitmapFactory.Options 替代直接解码」
//    - 16c6ca8「fix:优化连接」（同批次稳定性修复）
//  Android 用 BitmapFactory.Options.inJustDecodeBounds 只读尺寸、
//  inSampleSize 采样解码；iOS 用 ImageIO 的等价能力，避免整图解码。
//

#import "WKImageUtil.h"
#import <ImageIO/ImageIO.h>

// 缩略图/降采样默认最大边长。100KB 的 JPEG 缩略图最终尺寸远小于该值，
// 这里只是给解码一个内存上限，防止按原图分辨率解码。
static const NSUInteger WKImageDefaultMaxPixelSize = 1600;

@implementation WKImageUtil

+ (NSUInteger)defaultMaxPixelSize {
    return WKImageDefaultMaxPixelSize;
}

#pragma mark - 尺寸（只读，不解码）

+ (CGSize)imageSizeWithData:(NSData *)data {
    if(data.length == 0) {
        return CGSizeZero;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if(!source) {
        return CGSizeZero;
    }
    CGSize size = [self imageSizeWithSource:source];
    CFRelease(source);
    return size;
}

+ (CGSize)imageSizeWithFile:(NSString *)filePath {
    if(filePath.length == 0) {
        return CGSizeZero;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:filePath], NULL);
    if(!source) {
        return CGSizeZero;
    }
    CGSize size = [self imageSizeWithSource:source];
    CFRelease(source);
    return size;
}

+ (CGSize)imageSizeWithSource:(CGImageSourceRef)source {
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
    if(!properties) {
        return CGSizeZero;
    }
    CGFloat width = 0;
    CGFloat height = 0;
    CFNumberRef widthNum = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
    CFNumberRef heightNum = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
    if(widthNum) {
        CFNumberGetValue(widthNum, kCFNumberCGFloatType, &width);
    }
    if(heightNum) {
        CFNumberGetValue(heightNum, kCFNumberCGFloatType, &height);
    }
    // EXIF 方向 >= 5（旋转 90 度）时宽高互换，与下面缩略图的
    // kCGImageSourceCreateThumbnailWithTransform 保持一致的显示方向。
    int orientation = 1;
    CFNumberRef orientationNum = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
    if(orientationNum) {
        CFNumberGetValue(orientationNum, kCFNumberIntType, &orientation);
    }
    CFRelease(properties);
    if(orientation >= 5) {
        CGFloat tmp = width;
        width = height;
        height = tmp;
    }
    return CGSizeMake(width, height);
}

#pragma mark - 降采样解码

+ (UIImage *)downsampleImageWithData:(NSData *)data maxPixelSize:(NSUInteger)maxPixelSize {
    if(data.length == 0 || maxPixelSize == 0) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if(!source) {
        return nil;
    }
    UIImage *image = [self downsampleImageWithSource:source maxPixelSize:maxPixelSize];
    CFRelease(source);
    return image;
}

+ (UIImage *)downsampleImageWithFile:(NSString *)filePath maxPixelSize:(NSUInteger)maxPixelSize {
    if(filePath.length == 0 || maxPixelSize == 0) {
        return nil;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:filePath], NULL);
    if(!source) {
        return nil;
    }
    UIImage *image = [self downsampleImageWithSource:source maxPixelSize:maxPixelSize];
    CFRelease(source);
    return image;
}

+ (UIImage *)downsampleImageWithSource:(CGImageSourceRef)source maxPixelSize:(NSUInteger)maxPixelSize {
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize),
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if(!cgImage) {
        return nil;
    }
    UIImage *image = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return image;
}

+ (UIImage *)downsampleImage:(UIImage *)image maxPixelSize:(NSUInteger)maxPixelSize {
    if(!image || maxPixelSize == 0) {
        return image;
    }
    CGSize size = image.size;
    CGFloat maxSide = MAX(size.width, size.height);
    if(maxSide <= 0 || maxSide <= (CGFloat)maxPixelSize) {
        return image;
    }
    CGFloat scale = (CGFloat)maxPixelSize / maxSide;
    CGSize target = CGSizeMake(MAX(1, floor(size.width * scale)),
                               MAX(1, floor(size.height * scale)));
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [image drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result ?: image;
}

#pragma mark - 压缩

+ (NSData *)compressImage:(UIImage *)image toMaxBytes:(NSUInteger)maxBytes {
    if(!image) {
        return nil;
    }
    if(maxBytes == 0) {
        maxBytes = 1024 * 100;
    }
    CGFloat compression = 1;
    NSData *data = UIImageJPEGRepresentation(image, compression);
    if(!data) {
        return nil;
    }
    // 快路径：原图直接按质量 1 编码就已满足大小要求，保持原有行为（不改变分辨率）。
    if(data.length < maxBytes) {
        return data;
    }
    // 修复(OOM)：进入质量二分之前先按最大边长降采样。
    // 原实现在原图全分辨率上反复执行 UIImageJPEGRepresentation + UIGraphicsBeginImageContext，
    // 大图时会同时存在多张全尺寸位图/压缩缓冲，是 iOS 端图片 OOM 的主要来源。
    UIImage *workingImage = [self downsampleImage:image maxPixelSize:[self defaultMaxPixelSize]];
    if(!workingImage) {
        workingImage = image;
    }
    data = UIImageJPEGRepresentation(workingImage, compression);
    if(data.length < maxBytes) {
        return data;
    }
    // 压缩比采用二分法，6 次二分后的最小压缩比是 0.015625。
    CGFloat max = 1;
    CGFloat min = 0;
    for (int i = 0; i < 6; ++i) {
        compression = (max + min) / 2;
        data = UIImageJPEGRepresentation(workingImage, compression);
        if(!data) {
            break;
        }
        if (data.length < maxBytes * 0.9) {
            min = compression;
        } else if (data.length > maxBytes) {
            max = compression;
        } else {
            break;
        }
    }
    UIImage *resultImage = [UIImage imageWithData:data];
    if (data.length < maxBytes || !resultImage) {
        return data;
    }
    // 缩处理：按大小的比例缩减尺寸，因为有取整，一般需要两次处理。
    NSUInteger lastDataLength = 0;
    while (data.length > maxBytes && data.length != lastDataLength) {
        lastDataLength = data.length;
        CGFloat ratio = (CGFloat)maxBytes / data.length;
        CGSize size = CGSizeMake((NSUInteger)(resultImage.size.width * sqrtf(ratio)),
                                 (NSUInteger)(resultImage.size.height * sqrtf(ratio)));
        if(size.width < 1 || size.height < 1) {
            break;
        }
        UIGraphicsBeginImageContext(size);
        [resultImage drawInRect:CGRectMake(0, 0, size.width, size.height)];
        resultImage = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        if(!resultImage) {
            break;
        }
        data = UIImageJPEGRepresentation(resultImage, compression);
    }
    return data;
}

+ (NSData *)compressImageData:(NSData *)data toMaxBytes:(NSUInteger)maxBytes {
    if(data.length == 0) {
        return nil;
    }
    if(maxBytes == 0) {
        maxBytes = 1024 * 100;
    }
    // 关键：用 ImageIO 采样解码，解码阶段就只产生 <= maxPixelSize 的位图，
    // 不会像 [UIImage imageWithData:] 那样先按原分辨率整图解码（对应 Android inSampleSize）。
    UIImage *image = [self downsampleImageWithData:data maxPixelSize:[self defaultMaxPixelSize]];
    if(!image) {
        return nil;
    }
    return [self compressImage:image toMaxBytes:maxBytes];
}

@end
