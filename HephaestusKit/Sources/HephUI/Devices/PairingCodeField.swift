import SwiftUI

/// The 6-digit code field of the join flow (docs/ui/devices.md, "Step 2: enter the code"): it keeps the digits of what
/// is typed or pasted, at most 6.
struct PairingCodeField: View {
    @Binding private var code: String
    @FocusState private var isFocused: Bool

    init(code: Binding<String>) {
        _code = code
    }

    var body: some View {
        TextField("Code", text: $code)
            .labelsHidden()
            .font(.system(size: 28, design: .monospaced))
            .multilineTextAlignment(.center)
            .focused($isFocused)
            #if os(iOS)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            #endif
            .onChange(of: code, initial: true) {
                let digits = String(code.filter { ("0"..."9").contains($0) }.prefix(6))
                if digits != code {
                    code = digits
                }
            }
            .onAppear {
                isFocused = true
            }
    }
}
