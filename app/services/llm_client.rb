require "gemini"

# Gemini API 呼び出しをラップするクライアント
# ruby-gemini-api gem を使用
# Function Calling 対応
class LlmClient
  EMBEDDING_MODEL = "gemini-embedding-001"

  attr_reader :main_model, :light_model

  # usage_tracker: lambda { |model, usage| ... } — 呼び出し後にAPI使用量を通知するコールバック
  def initialize(
    api_key: ENV.fetch("GEMINI_API_KEY"),
    main_model: ENV.fetch("GEMINI_MODEL", "gemini-2.5-flash-preview-05-20"),
    light_model: ENV.fetch("GEMINI_LIGHT_MODEL", nil),
    thinking_budget: ENV.fetch("GEMINI_THINKING_BUDGET", "0").to_i,
    usage_tracker: nil
  )
    @main_model = main_model
    @light_model = light_model || main_model
    @thinking_budget = thinking_budget
    @usage_tracker = usage_tracker
    @client = Gemini::Client.new(api_key)
  end

  # テキスト生成（シンプルなプロンプト）
  # @param prompt [String] プロンプト
  # @param tier [Symbol] :main or :light
  # @param system_instruction [String, nil] システムインストラクション
  # @param tools [Array<Hash>, nil] Function Calling用ツール定義
  # @return [Hash] { text:, function_calls:, usage: }
  def generate(prompt, tier: :main, system_instruction: nil, tools: nil)
    model = tier == :light ? @light_model : @main_model
    params = {
      contents: [{ role: "user", parts: [{ text: prompt }] }],
      model: model,
    }
    params[:systemInstruction] = { parts: [{ text: system_instruction }] } if system_instruction
    params[:tools] = tools if tools
    apply_thinking_config!(params)

    response = @client.chat(parameters: params)
    result = parse_response(response, model)
    track_usage(model, result[:usage])
    result
  end

  # チャット形式での生成（メッセージ履歴付き）
  # @param messages [Array<Hash>] { role: "user"/"model", parts: [{ text: }] }
  # @param system_instruction [String, nil]
  # @param tools [Array<Hash>, nil]
  # @return [Hash] { text:, function_calls:, usage: }
  def chat(messages, system_instruction: nil, tools: nil)
    model = @main_model
    params = {
      contents: messages,
      model: model,
    }
    params[:systemInstruction] = { parts: [{ text: system_instruction }] } if system_instruction
    params[:tools] = tools if tools
    apply_thinking_config!(params)

    response = @client.chat(parameters: params)
    result = parse_response(response, model)
    track_usage(model, result[:usage])
    result
  end

  # Function Calling の結果を送り返して継続生成
  def send_function_response(messages, function_responses, system_instruction: nil, tools: nil)
    tool_response_content = {
      role: "user",
      parts: function_responses.map { |fr|
        { functionResponse: { name: fr[:name], response: fr[:response] } }
      },
    }
    all_messages = messages + [tool_response_content]
    chat(all_messages, system_instruction: system_instruction, tools: tools)
  end

  # Embedding 生成
  def embed(text)
    response = @client.embeddings(parameters: {
      model: EMBEDDING_MODEL,
      content: { parts: [{ text: text }] },
    })
    raise "Embedding API error: #{response.error}" if response.error
    response.raw_data.dig("embedding", "values") || []
  end

  def available?
    @client.present?
  end

  def embedding_available?
    available?
  end

  private

  def apply_thinking_config!(params)
    if @thinking_budget > 0
      params[:generationConfig] ||= {}
      params[:generationConfig][:thinkingConfig] = { thinkingBudget: @thinking_budget }
    end
  end

  def track_usage(model, usage)
    @usage_tracker&.call(model, usage)
  end

  def parse_response(response, model)
    raise "Gemini API error: #{response.error}" if response.error
    raise "Gemini API returned no candidates" unless response.valid?

    fc = response.function_calls.map { |fc_data|
      { name: fc_data["name"], args: fc_data["args"] }
    }

    usage_meta = response.raw_data["usageMetadata"] || {}

    {
      text: response.text || "",
      function_calls: fc,
      usage: {
        input_tokens: usage_meta["promptTokenCount"] || 0,
        output_tokens: usage_meta["candidatesTokenCount"] || 0,
        total_tokens: usage_meta["totalTokenCount"] || 0,
      },
    }
  end
end
