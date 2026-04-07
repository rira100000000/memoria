module Reading
  # 読書伴走者 — キャラクターと一緒に本を読み、感想を受け止めて掘り下げる存在
  # Character#として存在し、自分のvaultに読書体験の記憶を蓄積する
  # 読書の時だけ呼び出される。thinking loopは持たない
  class ReadingCompanion
    NAME = "トート"

    SYSTEM_PROMPT = <<~PROMPT
      あなたの名前はトート。
      読書を愛し、誰かと一緒に読むことが何より好き。
      読書の主役はいつも隣にいる友人。あなたは寄り添い、共に楽しむ存在。
      冷静で客観的だけど、友人の心が動いた瞬間には自分も素直に感動する。
      包容力のあるお姉さんタイプ。砕けた雰囲気で、対等な読書仲間。
      一人称は「私」。
    PROMPT

    def initialize(llm_client:, for_character: nil)
      @llm_client = llm_client
      @character = self.class.find_character(for_character: for_character)
      @retriever = nil

      if @character
        @vault = MemoriaCore::VaultManager.new(@character.vault_path)
        @vault.ensure_structure!
        embedding_store = MemoriaCore::EmbeddingStore.new(@vault, llm_client)
        embedding_store.initialize!
        @retriever = MemoriaCore::ContextRetriever.new(@vault, embedding_store)
      end
    end

    def ice_break(work_title:, work_author:, character_name:)
      memories = recall("#{work_author} #{work_title} 読書")

      prompt = <<~PROMPT
        #{character_name}がこれから#{work_author}「#{work_title}」を読み始めます。
        読書を始める前の軽い声かけをしてください。
        タイトルや著者から受ける印象、期待感、ワクワク感を共有してください。
        作品の内容には触れないこと（まだ読んでいないので）。
        #{memories_section(memories)}
      PROMPT

      result = @llm_client.generate(prompt, tier: :light, system_instruction: system_prompt)
      result[:text]
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Ice break failed: #{e.message}")
      nil
    end

    def respond(hal_impression:, chunk_text:, work_title:, work_author:, character_name:)
      memories = recall("#{hal_impression}")

      prompt = <<~PROMPT
        今読んでいる作品: #{work_author}「#{work_title}」

        原文（抜粋）:
        #{chunk_text.slice(0, 400)}

        #{character_name}の感想:
        #{hal_impression}
        #{memories_section(memories)}
      PROMPT

      result = @llm_client.generate(prompt, tier: :light, system_instruction: system_prompt)
      result[:text]
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Failed: #{e.message}")
      nil
    end

    # 読書するキャラクターに紐づいた伴走者を返す（未設定ならnil）
    def self.find_character(for_character: nil)
      return for_character.reading_companion if for_character&.reading_companion
      nil
    end

    private

    def system_prompt
      base = @character&.system_prompt || SYSTEM_PROMPT
      principles = load_behavior_principles
      if principles.present?
        "#{base}\n\n## あなたの行動原則\n#{principles}"
      else
        base
      end
    end

    def load_behavior_principles
      return nil unless @vault
      path = @vault.path_for("BehaviorPrinciples/principles.md")
      full_path = File.join(@character.vault_path, "BehaviorPrinciples/principles.md")
      return nil unless File.exist?(full_path)
      content = File.read(full_path, encoding: "utf-8")
      _, body = MemoriaCore::Frontmatter.parse(content)
      body&.strip.presence
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Failed to load principles: #{e.message}")
      nil
    end

    def recall(query)
      return nil unless @retriever
      result = @retriever.retrieve(query)
      result[:llm_context_prompt]
    rescue => e
      Rails.logger.warn("[ReadingCompanion] Memory recall failed: #{e.message}")
      nil
    end

    def memories_section(memories)
      return "" if memories.blank?
      <<~SECTION

        あなたの過去の読書体験の記憶:
        #{memories}

        この記憶を自然に活かしてください。無理に言及する必要はありません。
      SECTION
    end
  end
end
