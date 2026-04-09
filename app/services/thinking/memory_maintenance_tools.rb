module Thinking
  # 記憶整理用Function Callingツール
  # AIが自分の記憶を振り返り、統合・アーカイブを判断する
  class MemoryMaintenanceTools
    def self.definitions
      {
        functionDeclarations: [
          {
            name: "list_yesterdays_memories",
            description: "昨日の記憶（サマリーノート）一覧を確認する。記憶整理の最初のステップ。",
            parameters: { type: "OBJECT", properties: {} },
          },
          {
            name: "merge_memories",
            description: "複数の記憶を1つに統合する。似た内容や価値の低い記憶をまとめる時に使う。統合後のタイトルと要約を自分で書く。",
            parameters: {
              type: "OBJECT",
              properties: {
                memory_names: {
                  type: "ARRAY",
                  items: { type: "STRING" },
                  description: "統合するSNのベース名の配列",
                },
                merged_title: { type: "STRING", description: "統合後のタイトル" },
                merged_body: { type: "STRING", description: "統合後の要約本文" },
              },
              required: ["memory_names", "merged_title", "merged_body"],
            },
          },
          {
            name: "archive_memory",
            description: "記憶をアーカイブする。完全に忘れるのではなく、普段の想起対象から外す。重要でない記憶に使う。",
            parameters: {
              type: "OBJECT",
              properties: {
                memory_name: { type: "STRING", description: "アーカイブするSNのベース名" },
              },
              required: ["memory_name"],
            },
          },
        ],
      }
    end

    def self.execute(name, args, core:, character:, llm_client: nil)
      case name
      when "list_yesterdays_memories"
        list_yesterdays(core)
      when "merge_memories"
        merge(core, character,
          memory_names: args["memory_names"],
          merged_title: args["merged_title"],
          merged_body: args["merged_body"],
          llm_client: llm_client)
      when "archive_memory"
        archive(core, args["memory_name"], llm_client: llm_client)
      end
    end

    def self.list_yesterdays(core)
      yesterday = Date.current - 1
      sns = core.sns_for_date(yesterday)
      if sns.empty?
        { memories: "昨日の記憶はありません" }
      else
        items = sns.map { |s|
          source_label = s[:source] == "autonomous" ? "[自律]" : "[会話]"
          "#{source_label} #{s[:base_name]}\n  タイトル: #{s[:title]}\n  要点: #{Array(s[:key_takeaways]).first(2).join('; ')}"
        }
        { memories: items.join("\n\n"), count: sns.length }
      end
    end

    def self.merge(core, character, memory_names:, merged_title:, merged_body:, llm_client: nil)
      core.vault.versioning.commit_snapshot("pre_memory_merge")

      merged_base = core.sn_store.merge(
        memory_names,
        merged_title: merged_title,
        merged_body: "# #{merged_title}\n\n#{merged_body}",
        llm_role_name: character.name
      )

      # 統合SNのembeddingを更新
      if llm_client
        update_embedding(core, merged_base, llm_client)
        # アーカイブされたSNのembeddingを削除
        memory_names.each { |name| remove_embedding(core, name, llm_client) }
      end

      core.vault.versioning.commit_snapshot("memory_maintenance", "merge: #{memory_names.join(', ')} → #{merged_base}")

      { success: true, merged_as: merged_base, archived: memory_names }
    end

    def self.archive(core, memory_name, llm_client: nil)
      core.vault.versioning.commit_snapshot("pre_memory_archive")

      result = core.sn_store.archive(memory_name)
      return { error: "記憶が見つかりません: #{memory_name}" } unless result

      # embeddingから除外
      remove_embedding(core, memory_name, llm_client) if llm_client

      core.vault.versioning.commit_snapshot("memory_maintenance", "archive: #{memory_name}")

      { success: true, archived: memory_name }
    end

    class << self
      private

      def update_embedding(core, base_name, llm_client)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        path = core.sn_store.path_for("#{base_name}.md")
        content = core.vault.read(path)
        return unless content
        fm, = MemoriaCore::Frontmatter.parse(content)
        embedding_store.embed_and_store(path, content, "SN", {
          title: fm&.dig("title"),
          tags: fm&.dig("tags") || [],
        })
      end

      def remove_embedding(core, base_name, llm_client)
        embedding_store = MemoriaCore::EmbeddingStore.new(core.vault, llm_client)
        embedding_store.initialize!
        path = core.sn_store.path_for("#{base_name}.md")
        embedding_store.remove_entry(path) if embedding_store.respond_to?(:remove_entry)
      end
    end
  end
end
