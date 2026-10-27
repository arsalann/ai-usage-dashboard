import Foundation
import UsageCore

func runCodexTests() {
    test("parses live-shaped Codex usage response") {
        let json = """
        {"plan_type":"plus",
         "rate_limit":{"allowed":false,"limit_reached":true,
           "primary_window":{"used_percent":100,"limit_window_seconds":18000,
                             "reset_after_seconds":3637,"reset_at":1793129181},
           "secondary_window":{"used_percent":19,"limit_window_seconds":604800,
                               "reset_after_seconds":491934,"reset_at":1793617478}},
         "code_review_rate_limit":null,
         "credits":{"has_credits":false,"unlimited":false,"balance":"0"}}
        """
        let snapshot = try UsageSnapshot.parseCodex(from: Data(json.utf8))
        expectEqual(snapshot.session?.utilization, 100.0)
        expectEqual(snapshot.weekly?.utilization, 19.0)
        expectEqual(snapshot.session?.resetsAt, Date(timeIntervalSince1970: 1793129181))
        expectEqual(snapshot.weekly?.resetsAt, Date(timeIntervalSince1970: 1793617478))
    }

    test("parses Codex response without rate limits") {
        let snapshot = try UsageSnapshot.parseCodex(from: Data(#"{"plan_type":"plus","rate_limit":null}"#.utf8))
        expect(snapshot.session == nil, "session should be nil")
        expect(snapshot.weekly == nil, "weekly should be nil")
    }

    test("parses Codex window with missing reset time") {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":12.5},"secondary_window":null}}"#
        let snapshot = try UsageSnapshot.parseCodex(from: Data(json.utf8))
        expectEqual(snapshot.session?.utilization, 12.5)
        expect(snapshot.session?.resetsAt == nil, "resetsAt should be nil")
        expect(snapshot.weekly == nil, "weekly should be nil")
    }

    test("Codex parse throws on garbage") {
        expectThrows { _ = try UsageSnapshot.parseCodex(from: Data("nope".utf8)) }
    }

    test("parses ChatGPT-login auth.json") {
        let json = """
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
         "tokens":{"id_token":"id","access_token":"acc","refresh_token":"ref","account_id":"acct-1"},
         "last_refresh":"2026-10-27T00:00:00Z"}
        """
        expectEqual(CodexCredentials.parse(from: Data(json.utf8)),
                    CodexCredentials(accessToken: "acc", accountID: "acct-1"))
    }

    test("API-key auth.json has no usage credentials") {
        let json = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-test","tokens":null}"#
        expect(CodexCredentials.parse(from: Data(json.utf8)) == nil, "should be nil")
        expect(CodexCredentials.parse(from: Data("garbage".utf8)) == nil, "should be nil")
    }

    test("auth.json location honors CODEX_HOME") {
        expectEqual(CodexCredentials.defaultFileURL(environment: ["CODEX_HOME": "/tmp/cx"]).path,
                    "/tmp/cx/auth.json")
        expect(CodexCredentials.defaultFileURL(environment: [:]).path.hasSuffix("/.codex/auth.json"),
               "default should be ~/.codex/auth.json")
    }
}
