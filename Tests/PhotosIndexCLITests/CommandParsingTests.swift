import ArgumentParser
import XCTest
@testable import PhotosIndexCLI

final class CommandParsingTests: XCTestCase {
    func testGroupsInspectParsesAssetPageOptions() throws {
        let command = try XCTUnwrap(
            try PhotosIndexCommandLine.parseAsRoot([
                "groups", "inspect", "segment_test",
                "--index-run", "run_test",
                "--output", "/tmp/evidence",
                "--samples", "12",
                "--page", "2",
                "--page-size", "12",
                "--format", "json",
            ]) as? GroupsInspectCommand
        )

        XCTAssertEqual(command.page, 2)
        XCTAssertEqual(command.pageSize, 12)
    }

    func testDecisionAndExportCommandsParse() throws {
        XCTAssertTrue(
            try PhotosIndexCommandLine.parseAsRoot([
                "decisions", "validate", "--file", "/tmp/decision.json", "--format", "json",
            ]) is DecisionsValidateCommand
        )
        XCTAssertTrue(
            try PhotosIndexCommandLine.parseAsRoot([
                "export", "plan",
                "--decision", "/tmp/decision.json",
                "--to", "/tmp/Naver Clip",
                "--layout", "dated-group",
                "--output", "/tmp/plan.json",
                "--format", "json",
            ]) is ExportPlanCommand
        )
        XCTAssertTrue(
            try PhotosIndexCommandLine.parseAsRoot([
                "export", "apply",
                "--plan", "/tmp/plan.json",
                "--digest", String(repeating: "a", count: 64),
                "--format", "json",
            ]) is ExportApplyCommand
        )
        XCTAssertTrue(
            try PhotosIndexCommandLine.parseAsRoot([
                "move", "plan",
                "--decision", "/tmp/decision.json",
                "--to", "/tmp/Naver Clip",
                "--output", "/tmp/move-plan.json",
                "--format", "json",
            ]) is MovePlanCommand
        )
        XCTAssertTrue(
            try PhotosIndexCommandLine.parseAsRoot([
                "move", "apply",
                "--plan", "/tmp/move-plan.json",
                "--digest", String(repeating: "b", count: 64),
                "--format", "json",
            ]) is MoveApplyCommand
        )
    }
}
