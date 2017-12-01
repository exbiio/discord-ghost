module Ghost
  module DiscordEvents
    module ServerDelete
      extend Discordrb::EventContainer

      server_delete do |event|
        statement = $mysql.prepare("DELETE FROM servers WHERE sid=? LIMIT 1")
        statement.execute(event.server.id)
      end
    end
  end
end
