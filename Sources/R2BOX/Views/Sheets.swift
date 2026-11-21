import SwiftUI
import R2BOXCore

// MARK: - 连接表单（新建 / 编辑）

struct ConnectionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var endpoint = ""
    @State private var region = "auto"
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var pathStyle = true
    @State private var bucket = ""
    @FocusState private var nameFocused: Bool

    private var editing: Connection? { appState.editingConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(editing == nil ? "新建连接" : "编辑连接")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.top, 22)

            Form {
                Section("储存桶") {
                    TextField("名称", text: $name, prompt: Text("例如：团队文件"))
                        .focused($nameFocused)
                    TextField("Endpoint", text: $endpoint, prompt: Text("https://…"))
                    TextField("Region", text: $region)
                    TextField("储存桶名称", text: $bucket, prompt: Text("留空以列出所有储存桶"))
                    Toggle("Path-Style 寻址", isOn: $pathStyle)
                }
                Section("访问凭据") {
                    TextField("Access Key ID", text: $accessKey)
                    SecureField(
                        "Secret Access Key",
                        text: $secretKey,
                        prompt: editing == nil ? nil : Text("留空以保留现有密钥")
                    )
                }
            }
            .formStyle(.grouped)
            .defaultFocus($nameFocused, true)

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 500, height: 460)
        .onAppear { populate() }
    }

    private func populate() {
        if let e = editing {
            name = e.name
            endpoint = e.endpoint
            region = e.region
            accessKey = e.accessKeyID
            pathStyle = e.pathStyle
            bucket = e.bucket
            secretKey = ""
        } else {
            name = ""
            endpoint = ""
            region = "auto"
            accessKey = ""
            secretKey = ""
            pathStyle = true
            bucket = ""
        }
    }

    private var valid: Bool {
        !name.isEmpty && !endpoint.isEmpty && !accessKey.isEmpty &&
            (editing != nil || !secretKey.isEmpty)
    }

    private func save() {
        let trimmedBucket = bucket.trimmingCharacters(in: .whitespaces)
        if let e = editing {
            var updated = e
            updated.name = name
            updated.endpoint = endpoint
            updated.region = region
            updated.accessKeyID = accessKey
            updated.pathStyle = pathStyle
            updated.bucket = trimmedBucket
            ConnectionManager.shared.update(updated, secretKey: secretKey.isEmpty ? nil : secretKey)
        } else {
            let conn = Connection(
                name: name, endpoint: endpoint, region: region,
                accessKeyID: accessKey, pathStyle: pathStyle, bucket: trimmedBucket
            )
            ConnectionManager.shared.add(conn, secretKey: secretKey)
        }
        if let selected = ConnectionManager.shared.selected, editing == nil || editing?.id == selected.id {
            appState.connect(to: selected)
        }
    }
}

// MARK: - 重命名

struct RenameSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @FocusState private var nameFocused: Bool
    let entry: ObjectEntry

    private var originalName: String { (entry.key as NSString).lastPathComponent }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名").font(.title3.weight(.semibold))
            TextField("新名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("重命名") {
                    let name = newName
                    dismiss()
                    Task { await state.rename(entry, newName: name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty || newName == originalName)
            }
        }
        .padding(20)
        .frame(width: 380)
        .defaultFocus($nameFocused, true)
        .onAppear { newName = originalName }
    }
}

// MARK: - 新建文件夹

struct NewFolderSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建文件夹").font(.title3.weight(.semibold))
            TextField("文件夹名称", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFocused)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    let name = folderName
                    dismiss()
                    Task { await state.createFolder(name) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .defaultFocus($nameFocused, true)
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("工作区") {
                LabeledContent {
                    Button("在 Finder 中显示") { openURL(state.workspaceRoot.baseURL) }
                } label: {
                    Text("本地缓存目录")
                    Text(state.workspaceRoot.baseURL.path(percentEncoded: false))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}
