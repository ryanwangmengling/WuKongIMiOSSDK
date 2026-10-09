//
//  WKImageUtil.h
//  WuKongIMSDK
//
//  图片内存优化工具（ImageIO）
//
//  移植来源：WuKongIMAndroidSDK 的图片 OOM 修复
//    - 9c7878d / 151e946「改进图片尺寸获取方式防止OOM，使用 BitmapFactory.Options 替代直接解码」
//    - 16c6ca8「fix:优化连接」（同批次的稳定性修复）
//  Android 用 BitmapFactory.Options(inJustDecodeBounds) 只读尺寸、
//  用 inSampleSize 在解码阶段就按比例采样；iOS 对应的能力在 ImageIO，
//  本类把两者封装起来，避免 [UIImage imageWithData:] / imageWithContentsOfFile:
//  按原始分辨率整图解码造成的内存峰值。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WKImageUtil : NSObject

/// 缩略图/降采样默认最大边长（像素）。只是给解码一个上限，
/// 最终大小仍由 options.imageMaxBytes 的字节数目标决定。
@property (class, nonatomic, readonly) NSUInteger defaultMaxPixelSize;

/// 只读取像素尺寸，不把图片解码到内存。
/// 等价 Android 的 BitmapFactory.Options.inJustDecodeBounds。
/// 读取失败返回 CGSizeZero。
+ (CGSize)imageSizeWithData:(nullable NSData *)data;
+ (CGSize)imageSizeWithFile:(nullable NSString *)filePath;

/// 按最大边长降采样解码：解码阶段就只产生目标尺寸的位图，
/// 峰值内存由 maxPixelSize 决定。等价 Android 的 inSampleSize。
/// 失败返回 nil。
+ (nullable UIImage *)downsampleImageWithData:(nullable NSData *)data maxPixelSize:(NSUInteger)maxPixelSize;
+ (nullable UIImage *)downsampleImageWithFile:(nullable NSString *)filePath maxPixelSize:(NSUInteger)maxPixelSize;

/// 对已经在内存中的 UIImage 做降采样（避免 UIImageJPEGRepresentation /
/// UIGraphicsBeginImageContext 在原图全分辨率上进行，造成峰值内存过高）。
+ (nullable UIImage *)downsampleImage:(nullable UIImage *)image maxPixelSize:(NSUInteger)maxPixelSize;

/// 将图片压缩为不超过 maxBytes 的 JPEG（先降采样再质量二分）。
+ (nullable NSData *)compressImage:(nullable UIImage *)image toMaxBytes:(NSUInteger)maxBytes;

/// 将图片 data 压缩为不超过 maxBytes 的 JPEG。
/// 与 compressImage:toMaxBytes: 的区别：本方法用 ImageIO 直接采样解码，
/// 全程不会按原分辨率生成完整位图（原实现 [UIImage imageWithData:] 会）。
+ (nullable NSData *)compressImageData:(nullable NSData *)data toMaxBytes:(NSUInteger)maxBytes;

@end

NS_ASSUME_NONNULL_END
