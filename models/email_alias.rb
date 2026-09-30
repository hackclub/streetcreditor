class EmailAlias < ConfigRecord
  self.table_name = "Email Aliases"

  # ids for the airtable webhooks API, which speaks ids not names
  TABLE_ID = "tblu0DaU8ImDH7CpK"
  FIELD_PRIMARY = "fld3BBRAT9tRJlk3r"
  FIELD_ALIAS = "fldO72NY2ZaghU2C7"

  field :primary_email, "Primary Email"
  field :alias_email, "Alias Email"
end
