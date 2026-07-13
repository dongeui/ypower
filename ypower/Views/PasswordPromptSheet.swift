import SwiftUI

struct PasswordPromptSheet: View {
    let ssid: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\"\(ssid)\" 접속")
                .font(.headline)
            Text("이 네트워크는 처음 접속하는 네트워크입니다. 비밀번호를 입력해 주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("비밀번호", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(password) }
            HStack {
                Spacer()
                Button("취소", action: onCancel)
                Button("연결") { onSubmit(password) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
