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
        default:
            FileHandle.standardError.write(Data("unknown query \(args[0])\n".utf8))
            exit(2)
        }
    }
}
