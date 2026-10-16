import SwiftUI

struct FolderMembershipMenu: View {
  @ObservedObject var model: Workspace
  let folder: String
  var body: some View {
    Menu("그룹 이동") {
      Button {
        model.assignFolder(folder, to: nil)
      } label: {
        Label(
          "폴더 (기본 그룹)",
          systemImage: model.ungroupedFolders.contains(folder) ? "checkmark" : "folder")
      }
      Divider()
      ForEach(model.folderGroups) { group in
        Button {
          model.assignFolder(folder, to: group.id)
        } label: {
          Label(group.name, systemImage: group.folders.contains(folder) ? "checkmark" : group.icon)
        }
      }
      Divider()
      Button("새 그룹에 추가…") { model.editingGroup = FolderGroup(folders: [folder]) }
    }
  }
}

struct FolderGroupEditor: View {
  @ObservedObject var model: Workspace
  @State var draft: FolderGroup
  @Environment(\.dismiss) private var dismiss
  @FocusState private var nameFocused: Bool
  var choices: [String] {
    Array(Set(model.folders + draft.folders)).sorted {
      $0.localizedStandardCompare($1) == .orderedAscending
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("폴더 그룹").font(.title2.weight(.semibold))
      Text("폴더는 한 그룹에만 속합니다. 선택한 폴더는 다른 그룹에서 이 그룹으로 옮겨집니다.").foregroundStyle(.secondary).font(
        .callout)
      TextField("그룹 이름", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityLabel(
        "그룹 이름"
      ).focused($nameFocused)
      Text("그룹에 포함할 폴더").font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(choices, id: \.self) { folder in
            Toggle(
              isOn: Binding(
                get: { draft.folders.contains(folder) },
                set: { enabled in
                  draft.folders.removeAll { $0 == folder }
                  if enabled { draft.folders.append(folder) }
                })
            ) {
              Label(
                (folder == "." ? "최상위 문서" : folder)
                  + (model.folders.contains(folder) ? "" : " (폴더 없음)"), systemImage: "folder")
            }.toggleStyle(.checkbox)
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
      }.frame(height: 260).background(
        .quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
      HStack {
        Text("그룹 설정은 실제 디렉토리를 옮기지 않습니다.").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") {
          model.updateGroup(draft)
          dismiss()
        }.keyboardShortcut(.defaultAction)
          .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 540).onAppear { nameFocused = true }
  }
}
