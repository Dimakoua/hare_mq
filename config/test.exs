import Config
config :logger, level: :warning

config :hare_mq, :amqp,
  host: System.get_env("RABBITMQ_HOST", "rabbitmq"),
  url: System.get_env("RABBITMQ_URL", "amqp://" <> System.get_env("RABBITMQ_HOST", "rabbitmq")),
  user: System.get_env("RABBITMQ_USER", "guest"),
  password: System.get_env("RABBITMQ_PASSWORD", "guest")
