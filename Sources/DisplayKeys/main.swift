import AppKit

SettingsCarryOver.runIfNeeded()

let arguments = Array(CommandLine.arguments.dropFirst())
if CLI.handles(arguments) {
    exit(CLI.run(arguments))
}

// One instance only: a second one would install a second key tap and double every step.
guard AppInfo.otherInstance == nil else { exit(0) }

// Asked for before anything else can ask for the plain one: the first to ask decides its class.
let application = Application.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
