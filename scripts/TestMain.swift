// Entry point for the test binary that scripts/build.sh links. `swift test` doesn't use it.
import Darwin
import Testing

@main
struct TestMain {
    static func main() async {
        let status: CInt = await Testing.__swiftPMEntryPoint()
        exit(status)
    }
}
