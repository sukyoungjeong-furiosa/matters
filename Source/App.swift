import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
  weak var workspace: Workspace?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let workspace, let flush = workspace.flushRenderedEdits else {
      return workspace?.save() == false ? .terminateCancel : .terminateNow
    }
    Task { @MainActor in
      await flush()
      sender.reply(toApplicationShouldTerminate: workspace.save())
    }
    return .terminateLater
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }
}

#if !MODEL_TEST
  @main struct MattersApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var workspace = Workspace()
    var body: some Scene {
      WindowGroup("Matters") {
        MainView(model: workspace).onAppear { delegate.workspace = workspace }
      }.defaultSize(width: 1240, height: 800)
        .commands {
          CommandGroup(replacing: .newItem) {
            Button("새 문제…") { workspace.showNew = true }.keyboardShortcut("n")
            Button("작업 폴더 선택…") { workspace.chooseRoot() }.keyboardShortcut(
              "o", modifiers: [.command, .shift])
          }
          CommandGroup(after: .newItem) {
            Button("저장") { workspace.save() }.keyboardShortcut("s")
            Button("새로고침") { workspace.refresh() }.keyboardShortcut("r")
            Button("Finder에서 보기") { workspace.reveal() }.keyboardShortcut(
              "r", modifiers: [.command, .shift])
          }
          CommandMenu("문서") {
            Button("원문 / 문서 편집 전환") { workspace.changeMode(!workspace.renderedMode) }
              .keyboardShortcut("v", modifiers: [.command, .shift]).disabled(
                workspace.selected == nil)
          }
          CommandGroup(replacing: .textFormatting) {
            Button("굵게") { workspace.format(.bold) }.keyboardShortcut("b").disabled(
              workspace.selected == nil)
            Button("기울임") { workspace.format(.italic) }.keyboardShortcut("i").disabled(
              workspace.selected == nil)
            Button("코드 블록") { workspace.format(.codeBlock) }.keyboardShortcut("e").disabled(
              workspace.selected == nil)
          }
        }
    }
  }
#endif

struct MainView: View {
  @ObservedObject var model: Workspace
  @FocusState private var editorFocused: Bool
  var body: some View {
    NavigationSplitView {
      sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 235, max: 360)
    } content: {
      documentList.navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 450)
    } detail: {
      editor
    }
    .tint(Color(red: 0.16, green: 0.46, blue: 0.41))
    .frame(minWidth: 940, minHeight: 600)
    .toolbar {
      ToolbarItemGroup {
        Button {
          model.showNew = true
        } label: {
          Label("새 문제", systemImage: "square.and.pencil")
        }.help("새 문제 (⌘N)")
        Button {
          model.refresh()
        } label: {
          Label("새로고침", systemImage: "arrow.clockwise")
        }.help("외부 파일 변경 확인 (⌘R)")
        Button {
          model.reveal()
        } label: {
          Label("Finder에서 보기", systemImage: "folder")
        }
      }
    }
    .sheet(isPresented: $model.showNew) { FileSheet(model: model, mode: .create) }
    .sheet(isPresented: $model.showMove) { FileSheet(model: model, mode: .move) }
    .sheet(isPresented: $model.showRename) { FileSheet(model: model, mode: .rename) }
    .sheet(item: $model.editingGroup) { group in FolderGroupEditor(model: model, draft: group) }
    .sheet(item: $model.editingView) { view in RuleEditor(model: model, draft: view) }
    .alert(
      "작업을 완료하지 못했습니다",
      isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    ) {
      Button("확인") { model.error = nil }
    } message: {
      Text(model.error ?? "")
    }
  }
  var sidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Image(systemName: "square.stack.3d.up.fill").font(.title2).foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 3) {
          Text("Matters").font(.system(size: 21, weight: .semibold, design: .rounded))
          Text("생각에서 실행까지").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }.padding(18)
      List(selection: $model.scope) {
        Label("전체 문제", systemImage: "tray.full").badge(model.files.count).tag("all")
        Section("그룹") {
          ForEach(model.folderGroups) { group in
            HStack(spacing: 6) {
              Button {
                model.toggleGroupExpanded(group.id)
              } label: {
                Image(
                  systemName: model.collapsedGroups.contains(group.id)
                    ? "chevron.right" : "chevron.down"
                )
                .font(.caption).frame(width: 18, height: 24).contentShape(Rectangle())
              }.buttonStyle(.borderless).accessibilityLabel(
                group.name + (model.collapsedGroups.contains(group.id) ? " 펼치기" : " 접기"))
              Label(group.name, systemImage: group.icon)
              Spacer(minLength: 0)
            }.tag("group:" + group.id.uuidString)
              .badge(model.files.filter { group.includes($0) }.count)
              .contextMenu {
                Button("그룹 이름·폴더 편집…") { model.editingGroup = group }
                Button("그룹 삭제 (폴더 유지)", role: .destructive) { model.deleteGroup(group) }
              }
            if !model.collapsedGroups.contains(group.id) {
              ForEach(group.folders, id: \.self) { folder in
                if model.folders.contains(folder) {
                  FolderRow(model: model, folder: folder).padding(.leading, 22)
                    .tag("groupFolder:" + group.id.uuidString + ":" + folder)
                } else {
                  Label(folder + " (폴더 없음)", systemImage: "folder.badge.questionmark")
                    .foregroundStyle(.secondary).padding(.leading, 22)
                }
              }
            }
          }
          Button {
            model.editingGroup = FolderGroup()
          } label: {
            Label("그룹 만들기", systemImage: "plus.circle").frame(
              maxWidth: .infinity, alignment: .leading
            ).contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(.tint)
        }
        Section {
          if !model.defaultFoldersCollapsed {
            ForEach(model.ungroupedFolders, id: \.self) { folder in
              FolderRow(model: model, folder: folder).tag("folder:" + folder)
            }
          }
        } header: {
          Button {
            model.toggleDefaultFolders()
          } label: {
            HStack(spacing: 6) {
              Image(systemName: model.defaultFoldersCollapsed ? "chevron.right" : "chevron.down")
              Text("폴더")
              Spacer()
            }.contentShape(Rectangle())
          }.buttonStyle(.plain).accessibilityLabel(
            model.defaultFoldersCollapsed ? "기본 폴더 펼치기" : "기본 폴더 접기")
        }
        Section {
          ForEach(model.savedViews) { view in
            Label(view.name, systemImage: "line.3.horizontal.decrease.circle").badge(
              model.files.filter { view.matches($0) }.count
            ).tag("view:" + view.id.uuidString)
              .contextMenu {
                Button("조건 편집…") { model.editingView = view }
                Button("모아보기 삭제", role: .destructive) { model.deleteView(view) }
              }
          }
          Button {
            model.editingView = SavedView()
          } label: {
            Label("모아보기 만들기", systemImage: "plus.circle")
          }.buttonStyle(.plain).foregroundStyle(.tint)
        } header: {
          Text("모아보기")
        }
      }.listStyle(.sidebar)
      Divider()
      Button {
        model.chooseRoot()
      } label: {
        HStack {
          Image(systemName: "externaldrive")
          VStack(alignment: .leading) {
            Text(model.root.lastPathComponent).font(.callout.weight(.medium))
            Text("작업 폴더 변경").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
          Image(systemName: "chevron.up.chevron.down").font(.caption2)
        }.padding(14).contentShape(Rectangle())
      }.buttonStyle(.plain).help(model.root.path)
    }
  }
  var documentList: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text(model.scopeTitle).font(.headline).lineLimit(2)
          Text("\(model.visibleFiles.count)개의 문서").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if let group = model.activeGroup {
          Button {
            model.editingGroup = group
          } label: {
            Image(systemName: "slider.horizontal.3")
          }.buttonStyle(.borderless).help("그룹 이름과 폴더 편집")
        }
        if let view = model.activeView {
          Button {
            model.editingView = view
          } label: {
            Image(systemName: "slider.horizontal.3")
          }.buttonStyle(.borderless).help("모아보기 조건 편집")
        }
        Menu {
          Button("최근 수정 순") { model.sortByName = false }
          Button("이름 순") { model.sortByName = true }
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }.menuStyle(.borderlessButton).fixedSize().help("정렬")
      }.padding(16)
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("이 보기에서 검색", text: $model.search).textFieldStyle(.plain)
        if !model.search.isEmpty {
          Button {
            model.search = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
      }.padding(9).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.bottom, 12)
      Divider()
      if model.visibleFiles.isEmpty {
        VStack(spacing: 12) {
          Image(systemName: "doc.text.magnifyingglass").font(.system(size: 32, weight: .light))
            .foregroundStyle(.secondary)
          Text(model.search.isEmpty ? "아직 문서가 없어요" : "검색 결과가 없어요").font(.headline)
          Text(
            model.activeGroup != nil
              ? "그룹을 오른쪽 클릭해 폴더를 추가하세요."
              : model.activeView != nil ? "조건에 맞는 문서가 여기에 모입니다." : "자유롭게 적고, 필요한 곳으로 옮기세요."
          ).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          Button("새 문제 만들기") { model.showNew = true }.buttonStyle(.bordered)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        DocumentList(model: model)
      }
      if model.skipped > 0 {
        Text("UTF-8 텍스트가 아니거나 10MB를 넘는 파일 \(model.skipped)개는 표시하지 않습니다.").font(.caption2)
          .foregroundStyle(.secondary).padding(10)
      }
    }
  }
  var editor: some View {
    VStack(spacing: 0) {
      if let selected = model.selected {
        HStack(alignment: .center) {
          VStack(alignment: .leading, spacing: 5) {
            Text(selected.deletingPathExtension().lastPathComponent).font(
              .system(size: 20, weight: .semibold))
            Text(selected.path.replacingOccurrences(of: model.root.path + "/", with: "")).font(
              .caption
            ).foregroundStyle(.secondary).textSelection(.enabled)
          }
          Spacer()
          Button {
            model.togglePin(selected)
          } label: {
            Image(systemName: model.isPinned(selected) ? "pin.fill" : "pin")
          }
          .buttonStyle(.borderless).help(model.isPinned(selected) ? "고정 해제" : "목록 맨 위에 고정")
          .accessibilityLabel(model.isPinned(selected) ? "고정 해제" : "문서 고정")
          Menu {
            Button("이름 바꾸기…") { model.showRename = true }
            Button("다른 편집기로 열기") { if model.save() { NSWorkspace.shared.open(selected) } }
            Button("편집본 별도 저장…") { model.saveCopy() }
          } label: {
            Image(systemName: "ellipsis.circle")
          }.menuStyle(.borderlessButton).fixedSize()
          Menu {
            MoveDestinations(
              model: model, url: selected,
              currentFolder: model.files.first(where: { $0.url.path == selected.path })?.folder)
            Divider()
            Button("이름·위치 함께 변경…") { model.showMove = true }
          } label: {
            Label(
              model.files.first(where: { $0.url.path == selected.path })?.folder ?? "상태 변경",
              systemImage: "folder.badge.arrowshape.right")
          }.help("다른 상태 폴더를 선택하면 바로 이동합니다")
        }.padding(22)
        Divider()
        HStack {
          Label(
            model.renderedMode ? "문서 편집" : "원문 편집",
            systemImage: model.renderedMode ? "doc.richtext" : "pencil"
          )
          .font(.caption).foregroundStyle(.secondary)
          Spacer()
          Picker(
            "문서 모드", selection: Binding(get: { model.renderedMode }, set: { model.changeMode($0) })
          ) {
            Text("원문").tag(false)
            Text("문서 편집").tag(true)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
        }.padding(.horizontal, 22).padding(.vertical, 10)
        Divider()
        if model.conflict {
          VStack(alignment: .leading, spacing: 8) {
            Label("외부 파일을 덮어쓰지 않고 편집 내용을 보존하고 있어요.", systemImage: "exclamationmark.triangle").font(
              .callout)
            HStack {
              Button("편집본 별도 저장…") { model.saveCopy() }
              Button("외부 변경 불러오기…") { model.reloadExternal() }
            }
          }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(
            Color.orange.opacity(0.12))
        }
        if model.renderedMode {
          MarkdownDocumentEditor(
            text: model.text, documentURL: selected, rootURL: model.root,
            onEdit: { base, value in
              model.renderedEdit(url: selected, base: base, value: value)
            }, workspace: model,
            onOpenDocument: { url in
              if model.files.contains(where: { $0.url.path == url.path }) { model.select(url) }
            }
          ).id(selected.path)
        } else {
          TextEditor(text: Binding(get: { model.text }, set: { model.edited($0) }))
            .font(.system(size: 14, design: .monospaced)).scrollContentBackground(.hidden).padding(
              18
            ).background(Color(nsColor: .textBackgroundColor))
            .accessibilityLabel("문서 내용").focused($editorFocused)
        }
        Divider()
        HStack {
          Image(
            systemName: model.conflict
              ? "exclamationmark.circle" : model.dirty ? "circle.dotted" : "checkmark.circle"
          ).foregroundStyle(model.conflict ? .orange : .secondary)
          Text(model.message).lineLimit(1)
          Spacer()
          Text(
            "\(model.text.count)자 · \(model.renderedMode ? "셀 · 본문 직접 편집 · 자동 저장" : "일반 텍스트 · 자동 저장")"
          )
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 18).padding(.vertical, 10)
      } else {
        VStack(spacing: 18) {
          Image(systemName: "square.stack.3d.up").font(.system(size: 52, weight: .ultraLight))
            .foregroundStyle(.tint)
          Text("무엇이 신경 쓰이나요?").font(.system(size: 27, weight: .medium, design: .rounded))
          Text("떠오른 문제를 자유롭게 적어 두세요.\n폴더를 옮기며 생각을 발전시키고,\n나만의 조건으로 필요한 문제를 모아보세요.").font(
            .system(size: 14)
          ).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
          Button {
            model.showNew = true
          } label: {
            Label("새 문제", systemImage: "plus").padding(.horizontal, 12).padding(.vertical, 4)
          }.buttonStyle(.borderedProminent).padding(.top, 8)
          Text("문서는 내 폴더에, 형식은 내 마음대로.").font(.caption).foregroundStyle(.tertiary).padding(.top, 18)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
        HStack {
          Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
          Spacer()
        }.padding(14)
      }
    }
    .onChange(of: model.renderedMode) { _, rendered in
      if !rendered { DispatchQueue.main.async { editorFocused = true } }
    }
  }
}

struct MoveDestinations: View {
  @ObservedObject var model: Workspace
  let url: URL
  let currentFolder: String?
  var body: some View {
    ForEach(model.folders, id: \.self) { folder in
      Button {
        model.moveDocument(url, to: folder)
      } label: {
        if folder == currentFolder {
          Label(folder == "." ? "최상위 폴더" : folder, systemImage: "checkmark")
        } else {
          Text(folder == "." ? "최상위 폴더" : folder)
        }
      }.disabled(folder == currentFolder)
    }
  }
}

struct FolderRow: View {
  @ObservedObject var model: Workspace
  let folder: String
  @State private var isTargeted = false
  var body: some View {
    HStack {
      Label(
        folder == "." ? "최상위 문서" : folder, systemImage: isTargeted ? "folder.badge.plus" : "folder"
      ).lineLimit(2)
      Spacer(minLength: 0)
    }.padding(.vertical, 3).frame(maxWidth: .infinity).contentShape(Rectangle())
      .background(
        isTargeted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5)
      )
      .help("문서를 드래그하면 이동 · 오른쪽 클릭으로 그룹 이동")
      .contextMenu { FolderMembershipMenu(model: model, folder: folder) }
      .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
        guard providers.count == 1, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { object, loadError in
          Task { @MainActor in
            if let url = object as? URL {
              model.moveDocument(url, to: folder)
            } else {
              model.error = loadError?.localizedDescription ?? "문서의 파일 위치를 읽을 수 없습니다."
            }
          }
        }
        return true
      }
  }
}

enum FileSheetMode { case create, move, rename }
struct FileSheet: View {
  @ObservedObject var model: Workspace
  let mode: FileSheetMode
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var folder = "."
  @State private var bodyText = ""
  @State private var localError: String?
  var title: String { mode == .create ? "새 문제" : mode == .move ? "문서 이동" : "이름 바꾸기" }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title).font(.title2.weight(.semibold))
      Text(mode == .create ? "파일 이름과 위치만 정하세요. 내용과 형식은 자유입니다." : "일반 파일의 이름이나 위치를 바꿉니다.").font(
        .callout
      ).foregroundStyle(.secondary)
      TextField("파일 이름 (예: 생각해 볼 문제.md)", text: $name).textFieldStyle(.roundedBorder)
        .accessibilityLabel("파일 이름")
      Picker("폴더", selection: $folder) {
        ForEach(model.folders, id: \.self) { Text($0 == "." ? "최상위 폴더" : $0).tag($0) }
      }
      if mode == .create {
        Text("내용 · 비워 두어도 됩니다").font(.caption).foregroundStyle(.secondary)
        TextEditor(text: $bodyText).font(.system(size: 13, design: .monospaced)).frame(height: 200)
          .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
          .accessibilityLabel("새 문제 내용")
      }
      if let localError {
        Text(localError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button(mode == .create ? "만들기" : "적용") {
          let filename =
            mode == .create && (name as NSString).pathExtension.isEmpty ? name + ".md" : name
          let success =
            mode == .create
            ? model.create(name: filename, folder: folder, body: bodyText)
            : model.relocate(name: filename, folder: folder)
          if success {
            dismiss()
          } else {
            localError = model.error
            model.error = nil
          }
        }.keyboardShortcut(.defaultAction).disabled(
          name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(26).frame(width: 560)
      .onAppear {
        folder = model.defaultFolder
        if mode != .create, let selected = model.selected {
          name = selected.lastPathComponent
          folder = model.files.first(where: { $0.url == selected })?.folder ?? "."
        }
      }
  }
}

struct RuleEditor: View {
  @ObservedObject var model: Workspace
  @State var draft: SavedView
  @Environment(\.dismiss) private var dismiss
  var valid: Bool {
    !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.rules.isEmpty
      && draft.rules.allSatisfy { $0.error == nil }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("모아보기 조건").font(.title2.weight(.semibold))
      Text("문서를 바꾸지 않고, 원하는 내용이 있는 파일을 모읍니다.\n항목 이름이나 값은 정해져 있지 않습니다.").font(.callout)
        .foregroundStyle(.secondary)
      TextField("모아보기 이름", text: $draft.name).textFieldStyle(.roundedBorder)
      Picker("조건 결합", selection: $draft.matchAll) {
        Text("모든 조건에 맞는 문서").tag(true)
        Text("하나 이상 맞는 문서").tag(false)
      }.pickerStyle(.segmented)
      ScrollView {
        VStack(spacing: 14) {
          ForEach($draft.rules) { $rule in
            VStack(alignment: .leading, spacing: 9) {
              HStack {
                Picker("대상", selection: $rule.target) {
                  ForEach(RuleTarget.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 125)
                Picker("비교", selection: $rule.operation) {
                  ForEach(RuleOperation.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 165)
                Spacer()
                Toggle("대소문자 구분", isOn: $rule.caseSensitive).toggleStyle(.checkbox).font(.caption)
                Button {
                  draft.rules.removeAll { $0.id == rule.id }
                } label: {
                  Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).help("조건 삭제")
              }
              TextField("찾을 내용 · 예: 시급함: 매우", text: $rule.value).textFieldStyle(.roundedBorder)
              if let error = rule.error, !rule.value.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red)
              }
            }.padding(12).background(
              .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
          }
        }
      }.frame(minHeight: 100, maxHeight: 300)
      HStack {
        Button {
          draft.rules.append(Rule())
        } label: {
          Label("조건 추가", systemImage: "plus")
        }
        Spacer()
        Text(
          valid
            ? "현재 \(model.files.filter { draft.matches($0) }.count)개 문서가 일치합니다" : "이름과 조건을 입력해 주세요"
        ).font(.caption).foregroundStyle(.secondary)
      }
      Text("본문 전체를 그대로 검색합니다. 정규식으로 줄바꿈·여러 표기 방식도 표현할 수 있습니다. 조건은 이 Mac의 앱 설정에만 저장됩니다.").font(
        .caption
      ).foregroundStyle(.secondary)
      HStack {
        if model.savedViews.contains(where: { $0.id == draft.id }) {
          Button("모아보기 삭제", role: .destructive) {
            model.deleteView(draft)
            dismiss()
          }
        }
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") {
          model.updateView(draft)
          dismiss()
        }.keyboardShortcut(.defaultAction).disabled(!valid)
      }
    }.padding(26).frame(width: 650)
  }
}
