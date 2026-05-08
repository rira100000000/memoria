module MemoriaServer
  # OpenAI互換リクエスト + MS が把握する状態 から、アダプタへ渡す `context` Hash を組み立てる。
  #
  # MS の方針：受け取ったフィールドは破棄せずパススルーする。アダプタが必要なものを使う。
  module ContextBuilder
    # @param character [Character]
    # @param device [Device, nil] 現在 active なデバイス（ない場合 nil）
    # @param payload [Hash] OpenAI形式リクエストボディ（symbol or string keys 両対応）
    # @param last_interaction_at [Time, nil] このキャラの直近対話時刻（経過時間付与用）
    # @return [Hash] context payload
    def self.build(character:, device:, payload:, last_interaction_at: nil)
      h = payload.deep_symbolize_keys rescue payload
      messages = Array(h[:messages])

      {
        character_id: character.id,
        character_name: character.name,
        device_id: device&.id,
        device_slug: device&.slug,
        history: messages,                         # OpenAI形式の messages をそのままパススルー
        current_input: extract_current_input(messages),
        client_system_prompt: extract_system_prompt(messages),
        tools: h[:tools],
        tool_choice: h[:tool_choice],
        functions: h[:functions],                   # 旧名 function calling もパススルー
        client_metadata: h[:client_metadata] || h[:metadata] || {},
        last_interaction_at: last_interaction_at,
        elapsed_since: last_interaction_at ? (Time.current - last_interaction_at).to_i : nil,
      }
    end

    # messages 配列から「最後のユーザー発言」をテキストで取り出す。
    # vision でcontent が配列の場合は text part だけ連結する（画像はアダプタが履歴側で参照）。
    def self.extract_current_input(messages)
      last_user = messages.reverse.find { |m| (m[:role] || m["role"]).to_s == "user" }
      return nil unless last_user
      content = last_user[:content] || last_user["content"]
      return content if content.is_a?(String)
      # vision: content が parts の配列
      Array(content).map { |p|
        next p[:text] || p["text"] if p.is_a?(Hash) && (p[:type] == "text" || p["type"] == "text")
        nil
      }.compact.join("\n")
    end

    def self.extract_system_prompt(messages)
      sys = messages.select { |m| (m[:role] || m["role"]).to_s == "system" }
      return nil if sys.empty?
      sys.map { |m|
        c = m[:content] || m["content"]
        c.is_a?(String) ? c : nil
      }.compact.join("\n\n")
    end
  end
end
