import SwiftUI
import R2BOXCore
import R2BOXSync

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

    private var editing: Connection? { appState.editingConnection }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editing == nil ? "新建连接" : "编辑连接")
                .font(.headline)

            Form {
                TextField("名称", text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField("Endpoint", text: $endpoint)
                    .textFieldStyle(.roundedBorder)
                TextField("Region", text: $region)
                    .textFieldStyle(.roundedBorder)
                TextField("Access Key ID", text: $accessKey)
                    .textFieldStyle(.roundedBorder)
                SecureField("Secret Access Key", text: $secretKey)
                    .textFieldStyle(.roundedBorder)
                TextField("储存桶", text: $bucket)
                    .textFieldStyle(.roundedBorder)
                Toggle("Path-Style 寻址", isOn: $pathStyle)
            }
            .formStyle(.grouped)

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
        }
        .padding(18)
        .frame(width: 480)
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
        if let selected = ConnectionManager.shared.selected {
            appState.connect(to: selected)
        }
    }
}

// MARK: - 重命名

struct RenameSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("重命名").font(.headline)
            TextField("新名称", text: $newName)
                .textFieldStyle(.roundedBorder)
                .onAppear {
                    newName = state.renameTarget.map {
                        ($0.key as NSString).lastPathComponent
                    } ?? ""
                }
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") {
                    if let entry = state.renameTarget {
                        let name = newName
                        state.renameTarget = nil
                        Task { await state.rename(entry, newName: name) }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty || newName == state.renameTarget.map { ($0.key as NSString).lastPathComponent })
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - 新建文件夹

struct NewFolderSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建文件夹").font(.headline)
            TextField("文件夹名称", text: $folderName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    let name = folderName
                    state.folderTarget = nil
                    Task { await state.createFolder(name) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(folderName.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: - 设置

struct SettingsView: View {
    var body: some View {
        Form {
            Section("工作区") {
                LabeledContent("本地缓存目录") {
                    Text("~/Library/Application Support/R2BOX/workspace")
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            Section("说明") {
                Text("Endpoint 含 \"demo.\" 的连接使用内置 Mock 数据；其余 Endpoint 走真实 S3/R2（SigV4 签名 + 流式传输），Access Key 与 Secret 从 Keychain 读取。")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}
