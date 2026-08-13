# development/test は全許可、production は CORS_ORIGINS（カンマ区切り）で明示指定する
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    if Rails.env.production?
      origins ENV.fetch("CORS_ORIGINS", "").split(",").map(&:strip).reject(&:empty?)
    else
      origins "*"
    end

    resource "*",
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head]
  end
end
