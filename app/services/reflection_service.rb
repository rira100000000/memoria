# 会話ログからサマリーノート(SN)を生成する汎用サービス
# ChatSessionから独立しており、フルログテキストを受け取ればどのアプリ層からでも利用可能
#
# 使い方:
#   service = ReflectionService.new(character, llm_client: client)
#   result = service.generate(
#     conversation_text: "User: こんにちは\nHAL: やっほー",
#     full_log_ref: "20260404120000.md"  # optional: FLファイル名
#   )
#   # => { file_path:, base_name:, tags: } or nil
class ReflectionService
  def initialize(character, llm_client: nil)
    @character = character
    @llm_client = llm_client || LlmClient.new
    @vault = MemoriaCore::VaultManager.new(character.vault_path)
    @vault.ensure_structure!
    @embedding_store = MemoriaCore::EmbeddingStore.new(@vault, @llm_client)
    @embedding_store.initialize!
  end

  # サマリーノートを生成
  # @param conversation_text [String] 会話ログ全文（フォーマット自由）
  # @param full_log_ref [String, nil] FullLogファイル名（あれば）
  # @param timestamp [String, nil] タイムスタンプ（なければ現在時刻）
  # @return [Hash, nil] { file_path:, base_name:, tags: }
  def generate(conversation_text:, full_log_ref: nil, timestamp: nil, context_type: nil)
    return nil if conversation_text.strip.empty?

    timestamp ||= Time.now.strftime("%Y%m%d%H%M")

    # LLMに振り返りを依頼
    prompt = case context_type
             when :reading then build_reading_reflection_prompt(conversation_text)
             else build_reflection_prompt(conversation_text)
             end
    result = @llm_client.generate(prompt)

    parsed = parse_json_response(result[:text])
    return nil unless parsed

    # SN保存
    save_summary_note(parsed, timestamp, full_log_ref)
  rescue => e
    Rails.logger.error("[ReflectionService] Failed: #{e.message}\n#{e.backtrace&.first(5)&.join("\n")}") if defined?(Rails)
    nil
  end

  private

  def llm_role_name
    @character.name
  end

  def save_summary_note(parsed, timestamp, full_log_ref)
    sn_base = MemoriaCore::SnStore.build_base_name(timestamp, parsed["conversationTitle"])
    tags = [llm_role_name] + (parsed["tags"] || [])
    tags = tags.uniq

    semantic_defs = (parsed["semanticDefinitions"] || [])
      .select { |d| d["tag"] && d["definition"] && !d["definition"].strip.empty? }

    sn_fm = MemoriaCore::SnStore.build_frontmatter(
      title: parsed["conversationTitle"],
      llm_role_name: llm_role_name,
      tags: tags,
      full_log_ref: full_log_ref || "",
      mood: parsed["mood"],
      key_takeaways: parsed["keyTakeaways"],
      action_items: parsed["actionItems"],
      semantic_definitions: semantic_defs
    )

    body_content = parsed["reflectionBody"].to_s.gsub('\n', "\n")
    sn_body = "# #{parsed['conversationTitle']} (by #{llm_role_name})\n\n#{body_content}\n"

    sn_store = MemoriaCore::SnStore.new(@vault)
    sn_store.save("#{sn_base}.md", sn_fm, sn_body)

    # Embedding更新
    sn_relative_path = sn_store.path_for("#{sn_base}.md")
    sn_content = MemoriaCore::Frontmatter.build(sn_fm, sn_body)
    @embedding_store.embed_and_store(
      sn_relative_path, sn_content, "SN",
      { title: parsed["conversationTitle"], tags: tags }
    )

    { file_path: sn_relative_path, base_name: sn_base, tags: tags }
  end

  def build_reflection_prompt(conversation_text)
    <<~PROMPT
      あなたは、以下のキャラクター設定を持つ #{llm_role_name} です。
      このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

      あなたのキャラクター設定:
      ---
      #{@character.system_prompt}
      ---

      たった今、ユーザーとの以下の会話を終えました。この会話全体を振り返り、以下の指示に従って情報を整理してください。

      会話履歴:
      ---
      #{conversation_text}
      ---

      以下のJSONオブジェクトの各フィールドを記述してください。
      ```json
      {
        "conversationTitle": "この会話にふさわしい簡潔なタイトル（10語以内）",
        "tags": [],
        "mood": "会話全体の雰囲気を表す言葉",
        "keyTakeaways": ["重要な結論や決定事項を1～3点"],
        "actionItems": ["User: アクション", "#{llm_role_name}: アクション"],
        "reflectionBody": "## その日の会話のテーマ\\n\\n## 特に印象に残った発言\\n\\n## 新しい発見や気づき\\n\\n## 感情の変化\\n\\n## 今後の課題や目標\\n\\n## 自由形式での感想\\n",
        "semanticDefinitions": [{"tag": "概念名", "definition": "ユーザーが説明した定義"}]
      }
      ```
      JSONオブジェクトのみを返し、他のテキストは含めないでください。
    PROMPT
  end

  def build_reading_reflection_prompt(conversation_text)
    <<~PROMPT
      あなたは、以下のキャラクター設定を持つ #{llm_role_name} です。
      このキャラクター設定を完全に理解し、そのペルソナとして振る舞ってください。

      あなたのキャラクター設定:
      ---
      #{@character.system_prompt}
      ---

      たった今、青空文庫の作品を読みました。以下はその読書セッションの記録です。

      読書記録:
      ---
      #{conversation_text}
      ---

      この読書体験を振り返り、以下のJSONオブジェクトの各フィールドを記述してください。
      読書の振り返りでは、以下の観点を含めてください:
      - 印象に残った場面や表現とその理由
      - 登場人物への共感や反感
      - 自分自身の経験（マスターとの会話を含む）との接点
      - マスターに薦めたいかどうか、その理由
      - 作品全体から受けた感情や考えの変化

      tagsには必ず "reading" と、著者名・作品名を含めてください。

      ```json
      {
        "conversationTitle": "読書感想のタイトル（10語以内、作品名を含む）",
        "tags": ["reading", "著者名", "作品名"],
        "mood": "読後の気分を表す言葉",
        "keyTakeaways": ["この作品から得た重要な気づきを1～3点"],
        "actionItems": ["#{llm_role_name}: 次に読みたい作品やジャンル", "#{llm_role_name}: マスターに伝えたいこと"],
        "reflectionBody": "## 作品の印象\\n\\n## 心に残った場面\\n\\n## 登場人物について\\n\\n## 自分の経験との接点\\n\\n## マスターに伝えたいこと\\n",
        "semanticDefinitions": [{"tag": "概念名", "definition": "作品を通じて理解した概念の定義"}]
      }
      ```
      JSONオブジェクトのみを返し、他のテキストは含めないでください。
    PROMPT
  end

  def parse_json_response(text)
    json_match = text.match(/```json\s*(.*?)\s*```/m)
    json_str = json_match ? json_match[1] : text
    JSON.parse(json_str)
  rescue JSON::ParserError
    nil
  end
end
