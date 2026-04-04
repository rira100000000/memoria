require "faraday"
require "json"

# Gemini API 呼び出しをラップするクライアント
# Function Calling 対応
class LlmClient
  GEMINI_BASE_URL = "https://generativelanguage.googleapis.com/v1beta"
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
    @api_key = api_key
    @main_model = main_model
    @light_model = light_model || main_model
    @thinking_budget = thinking_budget
    @usage_tracker = usage_tracker
    @conn = Faraday.new(url: GEMINI_BASE_URL) do |f|
      f.request :json
      f.response :json
      f.adapter Faraday.default_adapter
      f.options.timeout = 120
      f.options.open_timeout = 10
    end
  end

  # テキスト生成
  # @param prompt [String] プロンプト
  # @param tier [Symbol] :main or :light
  # @param system_instruction [String, nil] システムインストラクション
  # @param tools [Array<Hash>, nil] Function Calling用ツール定義
  # @return [Hash] { text:, function_calls:, usage: }
  def generate(prompt, tier: :main, system_instruction: nil, tools: nil)
    model = tier == :light ? @light_model : @main_model
    body = build_generate_body(prompt, system_instruction: system_instruction, tools: tools)

    response = @conn.post("/v1beta/models/#{model}:generateContent?key=#{@api_key}", body)
    result = parse_generate_response(response)
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
    body = { contents: messages }
    body[:systemInstruction] = { parts: [{ text: system_instruction }] } if system_instruction
    body[:tools] = tools if tools
    if @thinking_budget > 0
      body[:generationConfig] = { thinkingConfig: { thinkingBudget: @thinking_budget } }
    end

    response = @conn.post("/v1beta/models/#{model}:generateContent?key=#{@api_key}", body)
    result = parse_generate_response(response)
    track_usage(model, result[:usage])
    result
  end

  # Function Calling の結果を送り返して継続生成
  def send_function_response(messages, function_responses, system_instruction: nil, tools: nil)
    # function_responses: [{ name:, response: { ... } }]
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
    body = {
      model: "models/#{EMBEDDING_MODEL}",
      content: { parts: [{ text: text }] },
    }
    response = @conn.post("/v1beta/models/#{EMBEDDING_MODEL}:embedContent?key=#{@api_key}", body)
    data = response.body
    raise "Embedding API error: #{data['error']&.dig('message') || response.status}" if data["error"]
    data.dig("embedding", "values") || []
  end

  def available?
    @api_key.present?
  end

  def embedding_available?
    available?
  end

  private

  def track_usage(model, usage)
    @usage_tracker&.call(model, usage)
  end

  def build_generate_body(prompt, system_instruction: nil, tools: nil)
    body = {
      contents: [{ role: "user", parts: [{ text: prompt }] }],
    }
    body[:systemInstruction] = { parts: [{ text: system_instruction }] } if system_instruction
    body[:tools] = tools if tools
    if @thinking_budget > 0
      body[:generationConfig] = { thinkingConfig: { thinkingBudget: @thinking_budget } }
    end
    body
  end

  def parse_generate_response(response)
    data = response.body
    if data["error"]
      raise "Gemini API error: #{data['error']['message']} (#{data['error']['code']})"
    end

    candidate = data.dig("candidates", 0)
    unless candidate
      raise "Gemini API returned no candidates"
    end

    parts = candidate.dig("content", "parts") || []
    text_parts = parts.select { |p| p["text"] }.map { |p| p["text"] }
    function_calls = parts.select { |p| p["functionCall"] }.map { |p|
      { name: p["functionCall"]["name"], args: p["functionCall"]["args"] }
    }

    usage = data["usageMetadata"] || {}

    {
      text: text_parts.join(""),
      function_calls: function_calls,
      usage: {
        input_tokens: usage["promptTokenCount"],
        output_tokens: usage["candidatesTokenCount"],
        total_tokens: usage["totalTokenCount"],
      },
    }
  end
end
