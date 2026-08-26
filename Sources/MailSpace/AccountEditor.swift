import AppKit

/// The add/edit-account sheet: display name, Google address, which services
/// the account offers, and an optional password that goes to the Keychain.
enum AccountEditor {
    struct Result {
        var name: String
        var email: String
        /// `nil` means "leave the stored password alone".
        var password: String?
        var clearPassword: Bool
        var mailEnabled: Bool
        var calendarEnabled: Bool
    }

    static func run(editing account: Account? = nil) -> Result? {
        let isEditing = account != nil
        let hasStoredPassword = account.map { KeychainStore.hasPassword(for: $0.email) } ?? false

        let alert = NSAlert()
        alert.messageText = isEditing ? "Account Settings" : "Add Account"
        alert.informativeText = isEditing
            ? "Change what this account is called, which Google services it shows, and its saved sign-in details."
            : "Name the account and pick which Google services it should show. You sign in to Google in the account's own view."
        alert.addButton(withTitle: isEditing ? "Save" : "Add")
        alert.addButton(withTitle: "Cancel")

        let nameField = textField(placeholder: "Work", value: account?.name ?? "")
        let emailField = textField(placeholder: "you@gmail.com", value: account?.email ?? "")
        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        passwordField.placeholderString = hasStoredPassword ? "Saved — type to replace" : "Optional, stored in your Keychain"

        let mailCheckbox = NSButton(checkboxWithTitle: "Mail", target: nil, action: nil)
        mailCheckbox.state = (account?.mailEnabled ?? true) ? .on : .off
        let calendarCheckbox = NSButton(checkboxWithTitle: "Calendar", target: nil, action: nil)
        calendarCheckbox.state = (account?.calendarEnabled ?? true) ? .on : .off

        let services = NSStackView(views: [mailCheckbox, calendarCheckbox])
        services.orientation = .horizontal
        services.spacing = 16

        var rows: [NSView] = [
            labelled("Name", nameField),
            labelled("Google address", emailField),
            labelled("Password", passwordField),
            hint("MailSpace fills the sign-in form for you. It never submits it, so two-factor stays manual. The password is kept only in your Keychain."),
            labelled("Show", services)
        ]
        if hasStoredPassword {
            let clear = NSButton(checkboxWithTitle: "Forget the saved password", target: nil, action: nil)
            clear.state = .off
            clear.identifier = NSUserInterfaceItemIdentifier("clearPassword")
            rows.append(labelled("", clear))
        }

        let form = NSStackView(views: rows)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(rows.count) * 34 + 10)
        alert.accessoryView = form
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let clearPassword = rows
            .flatMap { $0.subviews }
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "clearPassword" }?
            .state == .on

        var mail = mailCheckbox.state == .on
        let calendar = calendarCheckbox.state == .on
        // An account with no services would have nothing to show.
        if !mail && !calendar { mail = true }

        let password = passwordField.stringValue
        return Result(
            name: nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            email: emailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password.isEmpty ? nil : password,
            clearPassword: clearPassword,
            mailEnabled: mail,
            calendarEnabled: calendar
        )
    }

    // MARK: - Form pieces

    private static func textField(placeholder: String, value: String) -> NSTextField {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = placeholder
        field.stringValue = value
        return field
    }

    private static func labelled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        NSLayoutConstraint.activate([
            label.widthAnchor.constraint(equalToConstant: 106),
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 250)
        ])
        return row
    }

    private static func hint(_ text: String) -> NSView {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        NSLayoutConstraint.activate([label.widthAnchor.constraint(equalToConstant: 364)])
        return row
    }
}
