import SwiftUI

@main
struct OneImageCompareApp: App {
    @StateObject private var store = PhotoStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(store.theme.colorScheme)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开文件…") { store.openFiles() }
                    .keyboardShortcut("o")
                Button("打开文件夹…") { store.openFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Divider()
                Button("保存对比项目…") { store.saveProject() }
                    .keyboardShortcut("s")
                Button("打开对比项目…") { store.openProject() }
                    .keyboardShortcut("o", modifiers: [.command, .option])
            }
            CommandMenu("图像") {
                Button("进入对比") { store.enterCompare() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!(2...8).contains(store.selection.count))
                Button("切换 HDR/SDR") { store.toggleHDRMode() }
                    .keyboardShortcut("b", modifiers: [])
                Button("返回浏览") { store.mode = .browser }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("适合窗口") { store.resetView() }
                    .keyboardShortcut("/", modifiers: [])
                Button("放大") { store.changeZoom(by: 1.25) }
                    .keyboardShortcut("+", modifiers: [])
                Button("缩小") { store.changeZoom(by: 0.8) }
                    .keyboardShortcut("-", modifiers: [])
                Divider()
                Button("上一张") { store.selectAdjacent(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("下一张") { store.selectAdjacent(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("全选可见照片") { store.selectVisible(upTo: 8) }
                    .keyboardShortcut("a")
            }
            CommandMenu("导出") {
                Button("导出元数据 CSV…") { store.exportMetadataCSV() }
                Button("导出直方图 CSV…") { store.exportHistogramCSV() }
                Button("导出对比报告 PDF…") { store.exportPDF() }
            }
        }
        Settings {
            SettingsView().environmentObject(store)
        }
    }
}
