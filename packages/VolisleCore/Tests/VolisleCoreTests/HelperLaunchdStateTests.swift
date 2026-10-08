import Testing
@testable import VolisleCore

/// The launchd line of the diagnostics: was the background service ever started?
struct HelperLaunchdStateTests {
    @Test func keepsOnlyTheServicesOwnLines() {
        let printed = """
        system/top.qisw.volisle.mount-helper = {
        \tactive count = 1
        \tpath = (submitted by smd.375)
        \tstate = running
        \tprogram identifier = Contents/Library/LaunchServices/VolisleMountHelper (mode: 2)
        \truns = 1
        \tlast exit code = (never exited)
        \tspawn type = adaptive (6)
        \tjob state = running
        \tendpoints = {
        \t\t"top.qisw.volisle.mount-helper" = {
        \t\t\tstate = active
        \t\t}
        \t}
        }
        """
        let summary = HelperLaunchdState.summarize(printed, status: 0)
        #expect(summary == "state=running，runs=1，last exit code=(never exited)，job state=running，spawn type=adaptive (6)")
        // No paths: the program and submitter lines are not reported.
        #expect(!summary.contains("Contents/") && !summary.contains("smd"))
    }

    @Test func aMissingServiceSaysSo() {
        let summary = HelperLaunchdState.summarize("Bad request.\nCould not find service \"x\" in domain for system", status: 113)
        #expect(summary.contains("launchd"))
    }
}
