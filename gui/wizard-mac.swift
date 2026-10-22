// gui/wizard-mac.swift — the macOS setup window of rdms-backup.
// `backup.sh wizard` compiles this once (swiftc, cached under ~/Library/Caches/rdms-backup) and runs it with
// RDMS_BACKUP_SH (the script), RDMS_BASH (a bash >= 4) and BACKUP_CONF. Every decision lives in backup.sh: this window
// collects the answers, calls the script step by step (info, cloud-check, plan, init, setup --test-only, install,
// first-run) and shows its output. The password is stored from here through `security -i` on its stdin, never on a
// command line; the script then only tests the connection and keeps refusing any password passed to it.
import Cocoa

let environment = ProcessInfo.processInfo.environment
let scriptPath = environment["RDMS_BACKUP_SH"] ?? ""
let bashPath = environment["RDMS_BASH"] ?? "/bin/bash"

// MARK: - running backup.sh

final class Engine {
    struct Result { let code: Int32; let out: String }

    private func process(_ args: [String]) -> (Process, Pipe) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bashPath)
        p.arguments = [scriptPath] + args
        var env = ProcessInfo.processInfo.environment
        env["VERBOSE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        return (p, pipe)
    }

    /// Run to completion, return exit code and combined output.
    func capture(_ args: [String]) -> Result {
        let (p, pipe) = process(args)
        do { try p.run() } catch { return Result(code: 127, out: "could not run \(bashPath): \(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(code: p.terminationStatus, out: String(decoding: data, as: UTF8.self))
    }

    /// Run in the background; lines arrive on the main thread, then the exit code.
    @discardableResult
    func stream(_ args: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) -> Process? {
        let (p, pipe) = process(args)
        do { try p.run() } catch { onLine("could not run \(bashPath): \(error)"); onExit(127); return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            let h = pipe.fileHandleForReading
            var buffer = ""
            while true {
                let d = h.availableData
                if d.isEmpty { break }
                buffer += String(decoding: d, as: UTF8.self)
                while let r = buffer.range(of: "\n") {
                    let line = String(buffer[..<r.lowerBound])
                    buffer = String(buffer[r.upperBound...])
                    DispatchQueue.main.async { onLine(line) }
                }
            }
            if !buffer.isEmpty { let rest = buffer; DispatchQueue.main.async { onLine(rest) } }
            p.waitUntilExit()
            let code = p.terminationStatus
            DispatchQueue.main.async { onExit(code) }
        }
        return p
    }

    func json(_ args: [String]) -> [String: Any]? {
        let r = capture(args)
        guard r.code == 0, let d = r.out.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Keychain item via `security -i` (the command travels on stdin, so the secret is never in a process list).
    func storePassword(service: String, account: String, password: String) -> Bool {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let cmd = "add-generic-password -a \"\(esc(account))\" -s \"\(esc(service))\" -l \"RUG WebDAV backup (\(esc(account)))\" "
            + "-j \"read by \(esc(scriptPath))\" -T /usr/bin/security -U -w \"\(esc(password))\"\n"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["-i"]
        let input = Pipe()
        p.standardInput = input
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        input.fileHandleForWriting.write(Data(cmd.utf8))
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        // read-back without printing the secret
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        check.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do { try check.run() } catch { return false }
        check.waitUntilExit()
        return check.terminationStatus == 0
    }
}

// MARK: - the window

final class Wizard: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    enum Step: Int, CaseIterable {
        case welcome, account, folders, summary, password, schedule, done
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .account: return "Account"
            case .folders: return "Folders"
            case .summary: return "Summary"
            case .password: return "Password"
            case .schedule: return "Schedule and first backup"
            case .done: return "Done"
            }
        }
    }

    let engine = Engine()
    var info: [String: Any] = [:]
    var step: Step = .welcome
    var addMode = false          // adding folders to an existing several-folder setup
    var user = "@rug.nl"
    var folders: [String] = []
    var plan: [String: Any] = [:]
    var busy = false { didSet { refreshButtons() } }
    var tailTimer: Timer?

    var window: NSWindow!
    var stepLabels: [NSTextField] = []
    var titleLabel: NSTextField!
    var bodyBox: NSView!
    var statusLabel: NSTextField!
    var spinner: NSProgressIndicator!
    var logScroll: NSScrollView!
    var logView: NSTextView!
    var backButton: NSButton!
    var nextButton: NSButton!

    // step widgets
    var modeButtons: [NSButton] = []
    var addressField: NSTextField!
    var folderTable: NSTableView!
    var pw1: NSSecureTextField!
    var pw2: NSSecureTextField!

    // MARK: window building

    func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "RDMS backup setup"
        window.delegate = self
        window.center()
        let root = window.contentView!

        // left: step list
        let side = NSStackView()
        side.orientation = .vertical
        side.alignment = .leading
        side.spacing = 10
        side.edgeInsets = NSEdgeInsets(top: 24, left: 20, bottom: 20, right: 12)
        for s in Step.allCases {
            let l = NSTextField(labelWithString: s.title)
            l.font = NSFont.systemFont(ofSize: 13)
            stepLabels.append(l)
            side.addArrangedSubview(l)
        }
        let sideBox = NSVisualEffectView()
        sideBox.material = .sidebar
        sideBox.blendingMode = .behindWindow
        sideBox.translatesAutoresizingMaskIntoConstraints = false
        side.translatesAutoresizingMaskIntoConstraints = false
        sideBox.addSubview(side)
        root.addSubview(sideBox)

        // right: title, body, status + spinner, log, buttons
        titleLabel = NSTextField(labelWithString: "")
        titleLabel.font = NSFont.boldSystemFont(ofSize: 20)
        bodyBox = NSView()
        statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        logView = NSTextView()
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logScroll = NSScrollView()
        logScroll.documentView = logView
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true
        backButton = NSButton(title: "Back", target: self, action: #selector(back))
        nextButton = NSButton(title: "Continue", target: self, action: #selector(next))
        nextButton.keyEquivalent = "\r"
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .top
        statusRow.spacing = 8
        let buttons = NSStackView(views: [NSView(), backButton, nextButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        let right = NSStackView(views: [titleLabel, bodyBox, statusRow, logScroll, buttons])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 12
        right.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        right.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(right)

        NSLayoutConstraint.activate([
            sideBox.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sideBox.topAnchor.constraint(equalTo: root.topAnchor),
            sideBox.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sideBox.widthAnchor.constraint(equalToConstant: 200),
            side.leadingAnchor.constraint(equalTo: sideBox.leadingAnchor),
            side.topAnchor.constraint(equalTo: sideBox.topAnchor),
            side.trailingAnchor.constraint(equalTo: sideBox.trailingAnchor),
            right.leadingAnchor.constraint(equalTo: sideBox.trailingAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            bodyBox.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            bodyBox.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
            bodyBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            statusRow.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            statusRow.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
            logScroll.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            logScroll.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
            logScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            buttons.leadingAnchor.constraint(equalTo: right.leadingAnchor, constant: 24),
            buttons.trailingAnchor.constraint(equalTo: right.trailingAnchor, constant: -24),
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: helpers

    func log(_ line: String) {
        logView.string += line + "\n"
        logView.scrollToEndOfDocument(nil)
    }
    func clearLog() { logView.string = "" }
    func setStatus(_ s: String) { statusLabel.stringValue = s }

    func alert(_ text: String, _ informative: String = "", buttons: [String] = ["OK"]) -> Int {
        let a = NSAlert()
        a.messageText = text
        a.informativeText = informative
        for b in buttons { a.addButton(withTitle: b) }
        a.window.level = .modalPanel
        return a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func str(_ key: String, _ dict: [String: Any]? = nil) -> String { ((dict ?? info)[key] as? String) ?? "" }
    func flag(_ key: String) -> Bool { (info[key] as? Bool) ?? false }

    func reloadInfo() { info = engine.json(["info"]) ?? [:] }

    func refreshButtons() {
        backButton.isEnabled = !busy && [.account, .folders, .summary, .password].contains(step) && !(step == .folders && addMode)
        nextButton.isEnabled = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    func body(_ view: NSView) {
        bodyBox.subviews.forEach { $0.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyBox.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bodyBox.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyBox.trailingAnchor),
            view.topAnchor.constraint(equalTo: bodyBox.topAnchor),
            view.bottomAnchor.constraint(lessThanOrEqualTo: bodyBox.bottomAnchor),
        ])
    }

    func paragraph(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = NSFont.systemFont(ofSize: 13)
        return l
    }

    func stack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        for v in views { v.widthAnchor.constraint(lessThanOrEqualTo: s.widthAnchor).isActive = true }
        return s
    }

    // MARK: steps

    func show(_ s: Step) {
        step = s
        for (i, l) in stepLabels.enumerated() {
            let current = i == s.rawValue
            l.font = current ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 13)
            l.textColor = i <= s.rawValue ? .labelColor : .tertiaryLabelColor
        }
        titleLabel.stringValue = s.title
        setStatus("")
        nextButton.title = "Continue"
        logScroll.isHidden = ![.password, .schedule, .done].contains(s)
        switch s {
        case .welcome: showWelcome()
        case .account: showAccount()
        case .folders: showFolders()
        case .summary: showSummary()
        case .password: showPassword()
        case .schedule: showSchedule()
        case .done: showDone()
        }
        refreshButtons()
    }

    func showWelcome() {
        var views: [NSView] = [paragraph(
            "This sets up an automatic backup of one or more folders to your RUG research storage (RDMS).\n\n"
            + "It runs by itself at 3, 11, 15 and 19 h, keeps earlier versions of changed files for 90 days, checks after "
            + "every run that everything arrived, and tells you when something is wrong.\n\n"
            + "You will be asked for your RUG address, the folder(s), and your password (typed here, stored only on this Mac).")]
        let missing = (info["missing"] as? [String]) ?? []
        if !missing.isEmpty {
            views.append(paragraph("Missing on this Mac: \(missing.joined(separator: ", ")).\n"
                + "Install them first — paste into Terminal:   brew install rclone jq\nThen start the setup again."))
            nextButton.isEnabled = false
        } else if flag("config_exists") {
            modeButtons = []
            let several = flag("several_folders")
            let intro = paragraph("A backup is already set up: \(str("name")) (\(str("local_dir")) → \(str("remote"))).")
            let add = NSButton(radioButtonWithTitle: "Add folders to it", target: self, action: #selector(modeChanged))
            add.isEnabled = several
            let replace = NSButton(radioButtonWithTitle: "Replace it and start over (a different folder choice moves the backup to a new place on the server and uploads again)", target: self, action: #selector(modeChanged))
            let quit = NSButton(radioButtonWithTitle: "Keep it and quit", target: self, action: #selector(modeChanged))
            (several ? add : replace).state = .on
            modeButtons = [add, replace, quit]
            views.append(contentsOf: [intro, add, replace, quit])
        }
        body(stack(views))
    }
    @objc func modeChanged() {}

    func showAccount() {
        addressField = NSTextField(string: user)
        addressField.placeholderString = "name@rug.nl"
        addressField.delegate = self
        addressField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        body(stack([paragraph("Your RUG address:"), addressField]))
        window.makeFirstResponder(addressField)
    }

    func showFolders() {
        folderTable = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        col.title = "Folders to back up"
        col.width = 520
        folderTable.addTableColumn(col)
        folderTable.dataSource = self
        folderTable.delegate = self
        folderTable.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = folderTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 150).isActive = true
        let addB = NSButton(title: "Add folder…", target: self, action: #selector(addFolder))
        let remB = NSButton(title: "Remove", target: self, action: #selector(removeFolder))
        let row = NSStackView(views: [addB, remB])
        row.orientation = .horizontal
        let hint = paragraph(addMode
            ? "Folders inside \(str("local_dir")) can be added to this backup."
            : "Documents is the usual choice. Several folders become one backup; in the panel, Cmd-click selects several at once.")
        let s = stack([hint, scroll, row])
        scroll.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        body(s)
    }

    func showSummary() {
        var lines: [String] = []
        let fs = (plan["folders"] as? [String]) ?? []
        lines.append((fs.count > 1 ? "Folders:\n  " : "Folder:  ") + fs.joined(separator: "\n  "))
        if fs.count > 1 { lines.append("Backed up as parts of \(str("local_dir", plan))") }
        lines.append("Account:  \(user)")
        lines.append("On the server:  \(str("remote_path", plan))")
        lines.append("Runs at:  3, 11, 15, 19 h")
        lines.append("\nContinue writes the configuration. Next comes your password.")
        body(stack([paragraph(lines.joined(separator: "\n"))]))
    }

    func showPassword() {
        pw1 = NSSecureTextField(string: "")
        pw2 = NSSecureTextField(string: "")
        for f in [pw1!, pw2!] { f.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        body(stack([paragraph("WebDAV password for \(str("user")) (stored in your login keychain, used only by the backup):"),
                    pw1, paragraph("Once more, to rule out a typo:"), pw2]))
        clearLog()
        window.makeFirstResponder(pw1)
    }

    func showSchedule() {
        body(stack([paragraph("Installing the hourly schedule and starting the first backup…")]))
        nextButton.title = "Finish"
        runSchedule()
    }

    func showDone() {
        body(stack([paragraph("Done. The first backup runs in the background; with many files it takes hours, later runs "
            + "are quick. You can close this window.\n\nFrom now on it runs by itself. You hear from it when something is wrong, "
            + "and once a day at 3 am that all is well. In a terminal, 'backup.sh status' shows its health.")]))
        nextButton.title = "Close"
        backButton.isEnabled = false
    }

    // MARK: actions

    @objc func back() {
        switch step {
        case .account: show(.welcome)
        case .folders: show(.account)
        case .summary: show(.folders)
        case .password: show(.summary)
        default: break
        }
    }

    @objc func next() {
        switch step {
        case .welcome:
            if !modeButtons.isEmpty {
                if modeButtons[2].state == .on { NSApp.terminate(nil); return }
                addMode = modeButtons[0].state == .on
            }
            show(addMode ? .folders : .account)
        case .account:
            user = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let ok = user.range(of: #"^[A-Za-z0-9._%+-]*[A-Za-z0-9_%+-]@rug\.nl$"#, options: .regularExpression) != nil
            if !ok { _ = alert("'\(user)' does not look like a RUG address.", "Expected name@rug.nl."); return }
            show(.folders)
        case .folders:
            if folders.isEmpty { _ = alert("Choose at least one folder."); return }
            if addMode { addFoldersAndFinish(); return }
            var args = ["plan"]
            for f in folders { args += ["--folder", f] }
            guard let p = engine.json(args) else { _ = alert("Could not plan the backup.", engine.capture(args).out); return }
            plan = p
            show(.summary)
        case .summary:
            var args = ["init", "--user", user, "--remote-path", str("remote_path", plan), "--force", "--quiet"]
            for f in (plan["folders"] as? [String]) ?? [] { args += ["--folder", f] }
            let r = engine.capture(args)
            if r.code != 0 { _ = alert("Could not write the configuration.", r.out); return }
            reloadInfo()
            show(.password)
        case .password:
            storeAndTest()
        case .schedule:
            tailTimer?.invalidate()
            show(.done)
        case .done:
            NSApp.terminate(nil)
        }
    }

    @objc func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = addMode ? "Choose folders inside \(str("local_dir"))" : "Choose the folder(s) to back up"
        let start = addMode ? str("local_dir") : (folders.last.map { ($0 as NSString).deletingLastPathComponent } ?? str("local_dir"))
        panel.directoryURL = URL(fileURLWithPath: start.isEmpty ? NSHomeDirectory() : start)
        guard panel.runModal() == .OK else { return }
        let base = str("local_dir")
        for url in panel.urls {
            let path = url.path
            if folders.contains(path) { continue }
            if addMode && !path.hasPrefix(base.hasSuffix("/") ? base : base + "/") {
                _ = alert("\(path) is outside \(base).",
                          "It cannot be added to this backup. Including it means a new layout on the server: start the setup over (uploads again), or set up a second backup with 'backup.sh -c <name> wizard'.")
                continue
            }
            let c = engine.capture(["cloud-check", path])
            if c.code == 0 {
                let root = c.out.trimmingCharacters(in: .whitespacesAndNewlines)
                let choice = alert("\(path) lies inside a cloud-synced location (\(root)).",
                    "Files that exist only in the cloud would be downloaded by every run, and files already in the cloud gain little from a second copy.",
                    buttons: ["Leave it out", "Use it anyway"])
                if choice == 0 { continue }
            }
            folders.append(path)
        }
        folderTable.reloadData()
    }

    @objc func removeFolder() {
        let rows = folderTable.selectedRowIndexes
        folders = folders.enumerated().filter { !rows.contains($0.offset) }.map { $0.element }
        folderTable.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { folders.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { folders[row] }

    func storeAndTest() {
        let a = pw1.stringValue, b = pw2.stringValue
        if a.isEmpty { _ = alert("Please type the password."); return }
        if a != b { _ = alert("The two entries differ.", "Please type the password again in both fields."); pw2.stringValue = ""; window.makeFirstResponder(pw2); return }
        busy = true
        clearLog()
        setStatus("Storing the password in the keychain…")
        let service = str("keychain_service").isEmpty ? "rugbackup" : str("keychain_service")
        guard engine.storePassword(service: service, account: str("user"), password: a) else {
            busy = false
            setStatus("Could not store the password in the login keychain. Is this Mac's keychain locked? Try again at the Mac itself.")
            return
        }
        pw1.stringValue = ""; pw2.stringValue = ""
        setStatus("Testing the connection as \(str("user"))…")
        engine.stream(["setup", "--test-only"], onLine: { [weak self] l in self?.log(l) }, onExit: { [weak self] code in
            guard let self = self else { return }
            self.busy = false
            if code == 0 { self.show(.schedule) }
            else { self.setStatus("Could not connect as \(self.str("user")). Wrong password? Type it again. Wrong address? Go Back twice to correct it.") }
        })
    }

    func runSchedule() {
        busy = true
        clearLog()
        setStatus("Installing the schedule…")
        engine.stream(["install"], onLine: { [weak self] l in self?.log(l) }, onExit: { [weak self] code in
            guard let self = self else { return }
            if code != 0 { self.busy = false; self.setStatus("Installing the schedule failed; see the log. 'backup.sh install' in a terminal shows more."); return }
            self.setStatus("Starting the first backup…")
            self.engine.stream(["first-run"], onLine: { [weak self] l in self?.log(l) }, onExit: { [weak self] code in
                guard let self = self else { return }
                self.busy = false
                if code != 0 { self.setStatus("Could not start the first backup; see the log."); return }
                self.setStatus("The first backup is running. Its progress appears below; you may finish now, it continues in the background.")
                self.startTail()
            })
        })
    }

    func addFoldersAndFinish() {
        busy = true
        var args = ["init", "--add", "--quiet"]
        for f in folders { args += ["--folder", f] }
        let r = engine.capture(args)
        if r.code != 0 { busy = false; _ = alert("Could not update the folder list.", r.out); return }
        reloadInfo()
        logScroll.isHidden = false
        clearLog()
        setStatus("Starting a full pass to pick up the new folder(s)…")
        engine.stream(["first-run"], onLine: { [weak self] l in self?.log(l) }, onExit: { [weak self] code in
            guard let self = self else { return }
            self.busy = false
            if code != 0 { self.setStatus("Could not start the run; see the log. The folders are in the list and the next scheduled run picks them up."); return }
            self.startTail()
            self.show(.done)
        })
    }

    func startTail() {
        tailTimer?.invalidate()
        let path = str("log_dir") + "/latest/run.log"
        tailTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self, let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(14)
            self.logView.string = lines.joined(separator: "\n")
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    func windowWillClose(_ notification: Notification) { tailTimer?.invalidate(); NSApp.terminate(nil) }
}

// MARK: - app

final class AppDelegate: NSObject, NSApplicationDelegate {
    let wizard = Wizard()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit RDMS backup setup", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
        wizard.reloadInfo()
        wizard.build()
        wizard.show(.welcome)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if scriptPath.isEmpty {
    FileHandle.standardError.write(Data("wizard-mac: start it through 'backup.sh wizard'\n".utf8))
    exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
