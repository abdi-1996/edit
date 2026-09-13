import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import CoreML
import ImageIO

struct PhotoFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
struct Adjustments: Equatable { var light: Float = 0; var contrast: Float = 1; var color: Float = 1; var sharpness: Float = 0 }
final class PhotoEngine: @unchecked Sendable {
    static let shared = PhotoEngine()
    let context = CIContext(options: [.cacheIntermediates: false])
    func cg(_ image: CIImage) throws -> CGImage {
        guard let result = context.createCGImage(image, from: image.extent.integral) else { throw PhotoFailure(message: "Не удалось обработать фото. Возможно, недостаточно памяти.") }; return result
    }
    func decode(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData,nil), let result = CGImageSourceCreateThumbnailAtIndex(src,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096] as CFDictionary) else { throw PhotoFailure(message: "Не удалось открыть изображение.") }; return result
    }
    func adjust(_ image: CGImage, _ values: Adjustments) throws -> CGImage {
        let input = CIImage(cgImage:image)
        let filter = CIFilter.colorControls(); filter.inputImage=input; filter.brightness=values.light; filter.contrast=values.contrast; filter.saturation=values.color
        guard var output=filter.outputImage else { throw PhotoFailure(message:"Не удалось применить настройки.") }
        if values.sharpness > 0 { output=output.applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:values.sharpness]) }
        return try cg(output.cropped(to:input.extent))
    }
    func enhance(_ image: CGImage) throws -> CGImage {
        var output=CIImage(cgImage:image)
        for filter in output.autoAdjustmentFilters(options:[.enhance:true,.redEye:false]) { filter.setValue(output,forKey:kCIInputImageKey); if let next=filter.outputImage { output=next } }
        output=output.applyingFilter("CISharpenLuminance",parameters:[kCIInputSharpnessKey:0.45])
        return try cg(output.cropped(to:CGRect(x:0,y:0,width:image.width,height:image.height)))
    }
    func removeBackground(_ image: CGImage) throws -> CGImage {
        let handler=VNImageRequestHandler(cgImage:image,options:[:]); let request=VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result=request.results?.first, !result.allInstances.isEmpty else { throw PhotoFailure(message:"Не удалось выделить объект. Попробуй фото с более различимым фоном.") }
        let buffer=try result.generateMaskedImage(ofInstances:result.allInstances,from:handler,croppedToInstancesExtent:false)
        return try cg(CIImage(cvPixelBuffer:buffer))
    }
    func crop(_ image: CGImage, ratio: Double) throws -> CGImage {
        var w=Double(image.width),h=Double(image.height)
        if w/h>ratio { w=(h*ratio).rounded(.down) } else { h=(w/ratio).rounded(.down) }
        guard let out=image.cropping(to:CGRect(x:(Double(image.width)-w)/2,y:(Double(image.height)-h)/2,width:w,height:h).integral) else { throw PhotoFailure(message:"Не удалось обрезать фото.") }; return out
    }
    func rotate(_ image: CGImage) throws -> CGImage { try cg(CIImage(cgImage:image).oriented(.right)) }
    func mirror(_ image: CGImage) throws -> CGImage { try cg(CIImage(cgImage:image).oriented(.upMirrored)) }
    func png(_ image: CGImage) throws -> Data {
        guard let data=UIImage(cgImage:image).pngData() else { throw PhotoFailure(message:"Не удалось создать PNG.") }; return data
    }
    func resize(_ image: CGImage,width:Int,height:Int) throws -> CGImage {
        guard let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PhotoFailure(message:"Недостаточно памяти.") }
        c.interpolationQuality = .high; c.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); guard let out=c.makeImage() else { throw PhotoFailure(message:"Ошибка масштабирования.") };return out
    }
    func upscale(_ image:CGImage, scale:Int, progress:@escaping @Sendable (Double)->Void) throws -> CGImage {
        guard [2,4].contains(scale) else { throw PhotoFailure(message:"Допустим масштаб ×2 или ×4.") }
        guard image.width*scale <= 8192, image.height*scale <= 8192, image.width*image.height*scale*scale <= 24_000_000 else { throw PhotoFailure(message:"Результат превышает 24 Мп или 8192 px. Выбери ×2 или обрежь фото.") }
        guard let url=Bundle.main.url(forResource:"RealESRGAN",withExtension:"mlmodelc") else { throw PhotoFailure(message:"Модель Real-ESRGAN отсутствует в сборке.") }
        let config=MLModelConfiguration(); config.computeUnits = .all
        let model=try MLModel(contentsOf:url,configuration:config)
        guard let input=model.modelDescription.inputDescriptionsByName.first(where:{$0.value.type == .image}), let constraint=input.value.imageConstraint else { throw PhotoFailure(message:"Неподдерживаемый вход модели.") }
        let tileW=constraint.pixelsWide,tileH=constraint.pixelsHigh,pad=16
        guard tileW>pad*2,tileH>pad*2 else { throw PhotoFailure(message:"Некорректный размер модели.") }
        let stepW=tileW-pad*2,stepH=tileH-pad*2
        let cols=(image.width+stepW-1)/stepW,rows=(image.height+stepH-1)/stepH
        // A bitmap CGContext uses bottom-left coordinates; convert tile placement without flipping each image.
        guard let dest=CGContext(data:nil,width:image.width*scale,height:image.height*scale,bitsPerComponent:8,bytesPerRow:image.width*scale*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PhotoFailure(message:"Недостаточно памяти для результата.") }
        let ci=CIImage(cgImage:image)
        for row in 0..<rows { for col in 0..<cols {
            try Task.checkCancellation()
            try autoreleasepool {
                let x=col*stepW,y=row*stepH,w=min(stepW,image.width-x),h=min(stepH,image.height-y)
                // CI coordinates start at the lower-left, CGImage crop coordinates at the upper-left.
                let rect=CGRect(x:x-pad,y:image.height-y-tileH+pad,width:tileW,height:tileH)
                let tile=ci.clampedToExtent().cropped(to:rect).transformed(by:CGAffineTransform(translationX:-rect.minX,y:-rect.minY))
                var pixel:CVPixelBuffer?
                let status=CVPixelBufferCreate(kCFAllocatorDefault,tileW,tileH,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:] ] as CFDictionary,&pixel)
                guard status==kCVReturnSuccess,let pixel else { throw PhotoFailure(message:"Не удалось подготовить участок фото.") }
                context.render(tile,to:pixel)
                let prediction=try model.prediction(from:MLDictionaryFeatureProvider(dictionary:[input.key:MLFeatureValue(pixelBuffer:pixel)]))
                guard let name=prediction.featureNames.first,let feature=prediction.featureValue(for:name) else { throw PhotoFailure(message:"Модель не вернула изображение.") }
                let rendered:CGImage
                if let buffer=feature.imageBufferValue { rendered=try cg(CIImage(cvPixelBuffer:buffer)) }
                else if let array=feature.multiArrayValue { rendered=try fromArray(array) }
                else { throw PhotoFailure(message:"Неподдерживаемый результат модели.") }
                let native=rendered.width/tileW
                guard native>=2,rendered.height==tileH*native,let center=rendered.cropping(to:CGRect(x:pad*native,y:pad*native,width:w*native,height:h*native)) else { throw PhotoFailure(message:"Неверные размеры результата модели.") }
                dest.interpolationQuality = .high;dest.draw(center,in:CGRect(x:x*scale,y:(image.height-y-h)*scale,width:w*scale,height:h*scale))
            }
            progress(Double(row*cols+col+1)/Double(rows*cols))
        }}
        guard let rgb=dest.makeImage() else { throw PhotoFailure(message:"Не удалось собрать результат.") }
        // Preserve the source alpha mask independently: the RGB network cannot infer transparency.
        let alpha=CIImage(cgImage:image).transformed(by:CGAffineTransform(scaleX:CGFloat(scale),y:CGFloat(scale)))
        let result=CIImage(cgImage:rgb).applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:alpha.extent),kCIInputMaskImageKey:alpha])
        return try cg(result)
    }
    func fromArray(_ a:MLMultiArray) throws -> CGImage {
        let shape=a.shape.map{$0.intValue},strides=a.strides.map{$0.intValue}
        guard shape.count>=3 else { throw PhotoFailure(message:"Неверный тензор модели.") }
        let n=shape.count,h=shape[n-2],w=shape[n-1],channels=shape[n-3]
        guard channels==3 else { throw PhotoFailure(message:"Модель должна возвращать RGB.") }
        var bytes=[UInt8](repeating:255,count:w*h*4)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 { let offset=c*strides[n-3]+y*strides[n-2]+x*strides[n-1]; let value=a[offset].doubleValue;bytes[(y*w+x)*4+c]=UInt8(max(0,min(255,(value*255).rounded()))) } } }
        guard let provider=CGDataProvider(data:Data(bytes) as CFData),let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw PhotoFailure(message:"Ошибка чтения тензора.") }; return image
    }
}
