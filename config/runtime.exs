import Config

config :hare_mq, :amqp,
  host: System.get_env("RABBITMQ_HOST", "localhost"),
  url: System.get_env("RABBITMQ_URL", "amqp://guest:guest@localhost"),
  user: System.get_env("RABBITMQ_USER", "guest"),
  password: System.get_env("RABBITMQ_PASSWORD", "guest")
