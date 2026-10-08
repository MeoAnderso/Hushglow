import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
if CLI.handles(arguments) {
    exit(CLI.run(arguments))
}

// One instance only: a second one would install a second key tap and double every step.
guard AppInfo.otherInstance == nil else { exit(0) }

let delegate = AppDelegate()
let application = NSApplication.shared
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
