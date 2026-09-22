class EmailAlias < ConfigRecord
  self.table_name = "Email Aliases"

  field :primary_email, "Primary Email"
  field :alias_email, "Alias Email"
end
