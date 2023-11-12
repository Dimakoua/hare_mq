import Config
config :logger, level: :warn

config :hare_mq, :amqp,
  host: System.get_env("RABBITMQ_HOST", "localhost"),
  url: System.get_env("RABBITMQ_URL", "amqp://" <> System.get_env("RABBITMQ_HOST", "localhost")),
  user: System.get_env("RABBITMQ_USER", "guest"),
  password: System.get_env("RABBITMQ_PASSWORD", "guest")
