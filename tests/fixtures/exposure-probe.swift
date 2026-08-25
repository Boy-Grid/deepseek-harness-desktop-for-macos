// Exposes NetworkExposure's pure decisions to the shell test suite.
//
// Compiled against the app's own Preferences.swift, so what is checked is the
// code that ships rather than a copy of it. `isLoopback` in particular decides
// whether the user is warned before dsh starts listening where other machines
// can reach it, and a grep for the right hostnames cannot catch an inverted
// comparison.
//
//   exposure-probe loopback <host>      -> yes | no
//   exposure-probe authorities <text>   -> entries joined by '|', or <empty>
//   exposure-probe port <text>          -> the normalised port, or <invalid>
//   exposure-probe mirror-registry <n>  -> the preset's npm registry, or <none>
//   exposure-probe mirror-node <name>   -> the preset's Node base, or <none>
//   exposure-probe mirror-preset <name> -> the --mirror argument, or <none>
//   exposure-probe mirror-names         -> every case, joined by '|'
//   exposure-probe mirror-url <text>    -> yes | no
//
// Nothing here reads or writes UserDefaults: the probe must not leave a
// preferences domain behind on the machine that runs the tests.
import Foundation

@main
struct ExposureProbe {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 1 else {
            FileHandle.standardError.write(Data("usage: exposure-probe <what> [value]\n".utf8))
            exit(2)
        }
        let value = args.count >= 2 ? args[1] : ""
        switch args[0] {
        case "loopback":
            print(NetworkExposure.isLoopback(value) ? "yes" : "no")
        case "authorities":
            let list = NetworkExposure.parseAuthorities(value)
            print(list.isEmpty ? "<empty>" : list.joined(separator: "|"))
        case "port":
            print(NetworkExposure.normalizedPort(value) ?? "<invalid>")
        case "mirror-registry":
            print(NpmMirror(rawValue: value)?.registry ?? "<none>")
        case "mirror-node":
            print(NpmMirror(rawValue: value)?.nodeDist ?? "<none>")
        case "mirror-preset":
            print(NpmMirror(rawValue: value)?.presetArgument ?? "<none>")
        case "mirror-names":
            print(NpmMirror.allCases.map(\.rawValue).map { $0.isEmpty ? "(inherit)" : $0 }
                .joined(separator: "|"))
        case "mirror-url":
            print(NpmMirror.isUsableURL(value) ? "yes" : "no")
        default:
            FileHandle.standardError.write(Data("unknown query \(args[0])\n".utf8))
            exit(2)
        }
    }
}
