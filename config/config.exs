import Config

config :ash, default_string_length_count: :codepoints

config :spark, :formatter,
  remove_parens?: true,
  "Ash.Resource": [],
  "Ash.Domain": []
