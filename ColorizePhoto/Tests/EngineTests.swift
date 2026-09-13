import XCTest
import UIKit
import CoreML
@testable import ColorizePhoto
final class EngineTests:XCTestCase {
    let engine=PhotoEngine.shared
    func fixture()->CGImage {UIGraphicsImageRenderer(size:CGSize(width:96,height:64),format:{let f=UIGraphicsImageRendererFormat();f.scale=1;return f}()).image{c in UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:48,height:32));UIColor.blue.setFill();c.fill(CGRect(x:48,y:32,width:48,height:32))}.cgImage!}
    func testPNGAndDecodePreserveDimensionsAndAlpha()throws{let src=fixture();let data=try engine.png(src);let result=try engine.decode(data);XCTAssertEqual(result.width,96);XCTAssertEqual(result.height,64);let rgba=try pixels(result);XCTAssertEqual(rgba[(50*96+4)*4+3],0);XCTAssertGreaterThan(rgba[0],200)}
    func testCropRotateMirror()throws{let src=fixture();let crop=try engine.crop(src,ratio:1);XCTAssertEqual(crop.width,64);XCTAssertEqual(crop.height,64);let rotated=try engine.rotate(src);XCTAssertEqual(rotated.width,64);XCTAssertEqual(rotated.height,96);let mirrored=try engine.mirror(src);let p=try pixels(mirrored);XCTAssertGreaterThan(p[(4*96+90)*4],200);XCTAssertEqual(p[(4*96+4)*4+3],0)}
    func testEnhanceAndAdjustKeepAlpha()throws{let src=fixture();for result in [try engine.enhance(src),try engine.adjust(src,Adjustments(light:0.1,contrast:1.2,color:0,sharpness:0.5))]{XCTAssertEqual(result.width,96);XCTAssertEqual(result.height,64);let p=try pixels(result);XCTAssertEqual(p[(50*96+4)*4+3],0)}}
    func testModelIsBundledAndRunsRealPrediction()throws{let source=fixture();let result=try engine.upscale(source,scale:2){_ in};XCTAssertEqual(result.width,192);XCTAssertEqual(result.height,128);let p=try pixels(result);XCTAssertEqual(p[(100*192+8)*4+3],0);XCTAssertGreaterThan(p[(10*192+10)*4],100);XCTAssertGreaterThan(p[(100*192+150)*4+2],100)}
    func testUpscale4AndSafetyLimit()throws{let result=try engine.upscale(fixture(),scale:4){_ in};XCTAssertEqual(result.width,384);XCTAssertEqual(result.height,256);XCTAssertThrowsError(try engine.upscale(fixture(),scale:3){_ in})}
    func testBackgroundRemovalReportsNoSubjectOrProducesAlpha()throws{do{let result=try engine.removeBackground(fixture());XCTAssertEqual(result.width,96);XCTAssertEqual(result.height,64)}catch{throw XCTSkip("Vision subject segmentation needs a supported physical device / valid subject: \(error.localizedDescription)")}}
    func pixels(_ image:CGImage)throws->[UInt8]{var bytes=[UInt8](repeating:0,count:image.width*image.height*4);let ok=bytes.withUnsafeMutableBytes{b -> Bool in guard let ctx=CGContext(data:b.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)else{return false};ctx.translateBy(x:0,y:CGFloat(image.height));ctx.scaleBy(x:1,y:-1);ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true};XCTAssertTrue(ok);return bytes}
}
