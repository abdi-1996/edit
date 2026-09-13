import SwiftUI
import PhotosUI
import Photos
import UniformTypeIdentifiers

@main struct ColorizePhotoApp:App {
    var body:some Scene { WindowGroup { EditorView().preferredColorScheme(.dark).tint(Color(red:0.77,green:0.95,blue:0.42)) } }
}
@MainActor final class Editor:ObservableObject {
    @Published var image:CGImage?
    @Published var original:CGImage?
    @Published var busy=false
    @Published var progress=0.0
    @Published var message="Фото обрабатываются на устройстве"
    @Published var error:String?
    @Published var history:[CGImage]=[]
    @Published var adjustments=Adjustments()
    @Published var shareURL:URL?
    private var task:Task<Void,Never>?
    private var worker:Task<CGImage,Error>?
    private var generation=UUID()
    private var backgroundTask=UIBackgroundTaskIdentifier.invalid
    var canUndo:Bool { !history.isEmpty && !busy }
    func perform(_ title:String,_ operation:@escaping @Sendable () throws -> CGImage) {
        guard !busy else{return};busy=true;progress=0;message=title
        let id=UUID();generation=id
        backgroundTask=UIApplication.shared.beginBackgroundTask(withName:"Photo processing") { [weak self] in Task { @MainActor in self?.cancel() } }
        worker=Task.detached(priority:.userInitiated) { try operation() }
        let current=worker!
        task=Task { do { let output=try await current.value;guard generation==id else{return}; if let image{history.append(image);if history.count>3{history.removeFirst()}};image=output;adjustments=Adjustments();message="Готово · \(output.width) × \(output.height)";progress=1 } catch { if generation==id { self.error=error.localizedDescription;message="Фото не изменено" } };if generation==id{busy=false;endBackground()} }
    }
    func endBackground(){if backgroundTask != .invalid {UIApplication.shared.endBackgroundTask(backgroundTask);backgroundTask = .invalid}}
    func cancel(){generation=UUID();worker?.cancel();task?.cancel();busy=false;message="Обработка остановлена";endBackground()}
    func load(_ data:Data){perform("Открываем фотографию…"){try PhotoEngine.shared.decode(data)};Task{while busy{try? await Task.sleep(for:.milliseconds(80))};if error==nil{original=image;history=[]}}}
    func undo(){guard canUndo else{return};image=history.removeLast();adjustments=Adjustments();message="Изменение отменено"}
    func reset(){guard let original,!busy else{return};if let image{history.append(image);if history.count>3{history.removeFirst()}};image=original;adjustments=Adjustments();message="Оригинал восстановлен"}
    func background(){guard let image else{return};perform("Apple Vision · выделяем объект…"){try PhotoEngine.shared.removeBackground(image)}}
    func enhance(){guard let image else{return};perform("Enhanced · улучшаем свет и детали…"){try PhotoEngine.shared.enhance(image)}}
    func upscale(_ scale:Int){guard let image else{return};perform("Real-ESRGAN · подготовка модели…"){try PhotoEngine.shared.upscale(image,scale:scale){p in Task{@MainActor [weak self] in guard let self,self.busy else{return};self.progress=p;self.message="Real-ESRGAN · \(Int(p*100))%"}}}}
    func apply(){guard let image else{return};let values=adjustments;perform("Применяем настройки…"){try PhotoEngine.shared.adjust(image,values)}}
    func crop(_ ratio:Double){guard let image else{return};perform("Кадрирование…"){try PhotoEngine.shared.crop(image,ratio:ratio)}}
    func rotate(){guard let image else{return};perform("Поворот…"){try PhotoEngine.shared.rotate(image)}}
    func mirror(){guard let image else{return};perform("Отражение…"){try PhotoEngine.shared.mirror(image)}}
    func save(){guard let image,!busy else{return};Task{do{let data=try PhotoEngine.shared.png(image);let status=await PHPhotoLibrary.requestAuthorization(for:.addOnly);guard status == .authorized || status == .limited else {error="Разреши добавление фото в Настройках или используй «Поделиться».";return};try await PHPhotoLibrary.shared().performChanges{let request=PHAssetCreationRequest.forAsset();request.addResource(with:.photo,data:data,options:nil)};message="PNG сохранён в Фото"}catch{self.error=error.localizedDescription}}}
    func share(){guard let image else{return};do{let url=FileManager.default.temporaryDirectory.appendingPathComponent("Colorize-Photo-\(UUID().uuidString.prefix(8)).png");try PhotoEngine.shared.png(image).write(to:url);shareURL=url}catch{self.error=error.localizedDescription}}
}
struct EditorView:View {
    @StateObject var editor=Editor()
    @State var selected:PhotosPickerItem?
    @State var tab="ИИ"
    @State var compare=false
    @State var showFiles=false
    @State var showShare=false
    @State var showModels=false
    @State var cropRatio=1.0
    @State var zoom:CGFloat=1
    @GestureState var pinch:CGFloat=1
    @State var pan:CGSize = .zero
    @GestureState var drag:CGSize = .zero
    let lime=Color(red:0.77,green:0.95,blue:0.42)
    var body:some View {
        GeometryReader { geometry in
            VStack(spacing:0){header
                if geometry.size.width>760 {HStack(spacing:0){workspace.frame(maxWidth:.infinity);tools.frame(width:330).background(Color(white:0.105))}}
                else {VStack(spacing:0){workspace.frame(maxHeight:.infinity);tools.frame(maxHeight:330).background(Color(white:0.105))}}
            }.background(Color(white:0.055))
        }
        .onChange(of:selected){_,item in Task{do{if let data=try await item?.loadTransferable(type:Data.self){editor.load(data);zoom=1;pan = .zero}}catch{editor.error="Не удалось импортировать фото: \(error.localizedDescription)"}}}
        .fileImporter(isPresented:$showFiles,allowedContentTypes:[.image]){result in do {let url=try result.get();let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}};editor.load(try Data(contentsOf:url));zoom=1;pan = .zero}catch{editor.error=error.localizedDescription}}
        .sheet(isPresented:$showShare){if let url=editor.shareURL{ShareSheet(url:url)}}
        .sheet(isPresented:$showModels){modelSheet}
        .alert("Не удалось выполнить действие",isPresented:Binding(get:{editor.error != nil},set:{if !$0{editor.error=nil}})){Button("Понятно",role:.cancel){editor.error=nil}}message:{Text(editor.error ?? "")}
        .onAppear{if ProcessInfo.processInfo.arguments.contains("--uitesting"){editor.load(Self.fixture().pngData()!)}}
    }
    var header:some View {HStack{Image(systemName:"camera.aperture").font(.title2).foregroundStyle(lime);Text("COLORIZE").font(.system(size:17,weight:.bold,design:.rounded));Text("PHOTO").font(.caption).foregroundStyle(.gray);Spacer();Menu{Button("Сохранить в Фото",systemImage:"square.and.arrow.down"){editor.save()};Button("Поделиться PNG",systemImage:"square.and.arrow.up"){editor.share();showShare=editor.shareURL != nil}}label:{Text("Сохранить").font(.subheadline.bold()).padding(.horizontal,16).padding(.vertical,12).background(lime,in:Capsule()).foregroundStyle(.black)}.disabled(editor.image==nil || editor.busy).accessibilityIdentifier("saveMenu")}.padding(.horizontal,18).padding(.vertical,14)}
    var workspace:some View {VStack(spacing:10){HStack{Text(editor.image.map{"\($0.width) × \($0.height)"} ?? "НОВОЕ ФОТО").font(.caption.monospacedDigit()).foregroundStyle(.gray);Spacer();Button{editor.undo()}label:{Image(systemName:"arrow.uturn.backward").frame(width:44,height:36)}.disabled(!editor.canUndo).accessibilityIdentifier("undo");Button("Сбросить"){editor.reset()}.font(.subheadline).disabled(editor.image==nil || editor.busy)}
        GeometryReader{g in ZStack{Checkerboard().clipShape(RoundedRectangle(cornerRadius:18))
            if let image=compare ? editor.original : editor.image {Image(decorative:image,scale:1).resizable().scaledToFit().scaleEffect(zoom*pinch).offset(x:pan.width+drag.width,y:pan.height+drag.height).gesture(MagnificationGesture().updating($pinch){v,s,_ in s=v}.onEnded{zoom=min(8,max(1,zoom*$0));if zoom==1{pan = .zero}}).simultaneousGesture(DragGesture().updating($drag){v,s,_ in if zoom>1{s=v.translation}}.onEnded{if zoom>1{pan.width += $0.translation.width;pan.height += $0.translation.height}}).onTapGesture(count:2){zoom=1;pan = .zero}.accessibilityIdentifier("photoCanvas")}
            else {VStack(spacing:16){Image(systemName:"photo.badge.plus").font(.system(size:48,weight:.light)).foregroundStyle(lime);Text("Твой кадр.\nТвой взгляд.").font(.system(size:36,weight:.semibold,design:.rounded)).multilineTextAlignment(.center);PhotosPicker(selection:$selected,matching:.images){Text("Выбрать фотографию").font(.headline).padding().background(lime,in:Capsule()).foregroundStyle(.black)};Text("JPG, PNG, HEIC · без отправки в облако").font(.caption).foregroundStyle(.gray)}}
        }.frame(width:g.size.width,height:g.size.height).clipped()}.frame(minHeight:160)
        HStack{PhotosPicker(selection:$selected,matching:.images){Label("Фото",systemImage:"plus")}.disabled(editor.busy);Button{showFiles=true}label:{Image(systemName:"folder")}.disabled(editor.busy);Spacer();Text("\(Int(zoom*100))%").font(.caption.monospacedDigit()).foregroundStyle(.gray);Button{compare.toggle()}label:{Label(compare ? "После":"До",systemImage:"square.lefthalf.filled")}.disabled(editor.original==nil || editor.busy).accessibilityIdentifier("compare")}.font(.subheadline).buttonStyle(.bordered)
        Text(editor.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).accessibilityIdentifier("status")
        if editor.busy {HStack{ProgressView(value:editor.progress).tint(lime);Button("Стоп"){editor.cancel()}.font(.caption)}}
    }.padding(.horizontal,16).padding(.bottom,12)}
    var tools:some View {VStack(spacing:0){HStack(spacing:4){ForEach([("ИИ","sparkles"),("Свет","sun.max"),("Цвет","circle.lefthalf.filled"),("Кадр","crop")],id:\.0){name,icon in Button{tab=name}label:{VStack(spacing:6){Image(systemName:icon).font(.title3);Text(name).font(.caption)}.frame(maxWidth:.infinity).padding(.vertical,12).foregroundStyle(tab==name ? lime:Color.gray).background(tab==name ? lime.opacity(0.1):.clear,in:RoundedRectangle(cornerRadius:12))}.accessibilityIdentifier("tab-\(name)")}}.padding(12)
        ScrollView{VStack(spacing:12){if tab=="ИИ"{action("Удалить фон","Apple Vision · прозрачный PNG","person.crop.rectangle",id:"removeBackground"){editor.background()};HStack{action("Upscale ×2","Real-ESRGAN","arrow.up.left.and.arrow.down.right",id:"upscale2"){editor.upscale(2)};action("Upscale ×4","Максимум деталей","sparkle.magnifyingglass",id:"upscale4"){editor.upscale(4)}};action("Enhanced","Автосвет, цвет и чёткость","wand.and.stars",id:"enhance"){editor.enhance()};Button("ИИ-модели и качество"){showModels=true}.font(.caption).padding(4)}
            if tab=="Свет"{adjustSlider("Яркость",value:$editor.adjustments.light,range:-0.3...0.3);adjustSlider("Контраст",value:$editor.adjustments.contrast,range:0.5...1.8);adjustSlider("Чёткость",value:$editor.adjustments.sharpness,range:0...1.5);Button("Применить настройки"){editor.apply()}.buttonStyle(.borderedProminent).accessibilityIdentifier("applyAdjustments")}
            if tab=="Цвет"{adjustSlider("Насыщенность",value:$editor.adjustments.color,range:0...2);HStack{Button("Ч/Б"){editor.adjustments.color=0;editor.apply()};Button("Яркий"){editor.adjustments.color=1.2;editor.apply()}}.buttonStyle(.bordered);Button("Применить цвет"){editor.apply()}.buttonStyle(.borderedProminent)}
            if tab=="Кадр"{Text("Обрезка по центру").font(.subheadline);Picker("Пропорции",selection:$cropRatio){Text("1:1").tag(1.0);Text("4:3").tag(4.0/3);Text("3:4").tag(3.0/4);Text("16:9").tag(16.0/9);Text("9:16").tag(9.0/16)}.pickerStyle(.segmented);Button("Обрезать"){editor.crop(cropRatio);zoom=1;pan = .zero}.buttonStyle(.borderedProminent).accessibilityIdentifier("crop");HStack{Button("Повернуть",systemImage:"rotate.right"){editor.rotate()};Button("Отразить",systemImage:"arrow.left.and.right.righttriangle.left.righttriangle.right"){editor.mirror()}}.buttonStyle(.bordered)}
        }.padding(.horizontal,16).padding(.bottom,16).disabled(editor.image==nil || editor.busy)}
    }}
    func action(_ title:String,_ subtitle:String,_ icon:String,id:String,run:@escaping()->Void)->some View {Button(action:run){HStack(spacing:12){Image(systemName:icon).font(.title3).foregroundStyle(lime);VStack(alignment:.leading,spacing:5){Text(title).font(.system(size:15,weight:.semibold));Text(subtitle).font(.system(size:11)).foregroundStyle(.gray)};Spacer(minLength:0)}.padding(14).frame(maxWidth:.infinity,alignment:.leading).background(Color(white:0.16),in:RoundedRectangle(cornerRadius:14))}.foregroundStyle(.white).accessibilityIdentifier(id)}
    func adjustSlider(_ title:String,value:Binding<Float>,range:ClosedRange<Float>)->some View {VStack{HStack{Text(title);Spacer();Text(value.wrappedValue,format:.number.precision(.fractionLength(2))).foregroundStyle(lime).monospacedDigit()};Slider(value:value,in:range).accessibilityLabel(title)}.font(.subheadline)}
    var modelSheet:some View {NavigationStack{List{Section("Удаление фона"){Label("Apple Vision · встроена в iOS",systemImage:"checkmark.seal.fill");Text("Выделяет объекты и создаёт прозрачный фон. Работает без сервера.").font(.subheadline)};Section("AI Upscale"){Label("Real-ESRGAN x4plus · Core ML",systemImage:"cpu");Text("Полная модель. Увеличение ×4; режим ×2 уменьшает результат модели до двойного размера. Обработка по участкам с перекрытием сохраняет детали и снижает расход памяти.").font(.subheadline);Text("Ограничение результата: 24 Мп и 8192 px по стороне. Импорт фото — до 4096 px по длинной стороне.").font(.subheadline)};Section("Enhanced"){Text("Автоматическая коррекция Core Image и повышение чёткости. Это не генеративная ИИ-модель.")};Section("Качество"){Text("Сохранение в PNG без потерь, с прозрачностью. Нейросеть может дорисовывать детали — мелкий текст и лица проверяй сравнением «До / После».")}}.navigationTitle("Модели").toolbar{Button("Готово"){showModels=false}}}}
    static func fixture()->UIImage {UIGraphicsImageRenderer(size:CGSize(width:128,height:96)).image{c in UIColor.systemBlue.setFill();c.fill(CGRect(x:0,y:0,width:128,height:96));UIColor.systemYellow.setFill();c.fill(CGRect(x:16,y:12,width:48,height:50));UIColor.systemRed.setFill();c.fill(CGRect(x:80,y:56,width:30,height:25))}}
}
struct Checkerboard:View {var body:some View {Canvas{context,size in let cell:CGFloat=16;for row in 0..<Int(size.height/cell+1){for col in 0..<Int(size.width/cell+1){let color=Color(white:(row+col)%2==0 ? 0.10:0.13);context.fill(Path(CGRect(x:CGFloat(col)*cell,y:CGFloat(row)*cell,width:cell,height:cell)),with:.color(color))}}}}}
struct ShareSheet:UIViewControllerRepresentable {let url:URL;func makeUIViewController(context:Context)->UIActivityViewController{UIActivityViewController(activityItems:[url],applicationActivities:nil)};func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}}
