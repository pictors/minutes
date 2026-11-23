import Foundation

/// 要約プロバイダ共通の JSON Schema。
public enum SummarySchema {
    public static var json: [String: Any] {
        func evidence() -> [String: Any] {
            ["type": "array", "items": ["type": "integer"], "description": "根拠となる発言の segment id（[seg N] の N）"]
        }
        func object(_ properties: [String: Any], required: [String]) -> [String: Any] {
            ["type": "object", "additionalProperties": false, "properties": properties, "required": required]
        }
        return object([
                "summary_md": ["type": "string", "description": "会議の要約（Markdown、日本語、5〜15 行）"],
                "decisions": ["type": "array", "items": object(["text": ["type": "string"], "evidence": evidence()], required: ["text", "evidence"])],
                "action_items": ["type": "array", "items": object([
                    "text": ["type": "string"],
                    "owner": ["type": "string", "description": "me | 参加者名 | agent"],
                    "kind": ["type": "string", "enum": ["own_commitment", "their_task", "delegable"]],
                    "due": ["type": ["string", "null"], "description": "期限 YYYY-MM-DD。不明なら null"],
                    "evidence": evidence(),
                ], required: ["text", "owner", "kind", "due", "evidence"])],
                "open_questions": ["type": "array", "items": object(["text": ["type": "string"], "evidence": evidence()], required: ["text", "evidence"])],
                "keyterms_learned": ["type": "array", "items": ["type": "string"], "description": "次回の音声認識に役立つ固有名詞・専門用語"],
            ], required: ["summary_md", "decisions", "action_items", "open_questions", "keyterms_learned"])
    }
}
