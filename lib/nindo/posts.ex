defmodule Nindo.Posts do
  @moduledoc false

  alias NinDB.{Database, Post}
  alias Nindo.{Feeds}
  import Nindo.Core

  def new(title, body, image, user) do
      result =
        %{author_id: user.id, title: title, body: body, image: image, datetime: datetime()}
        |> Database.put(Post)

      Feeds.update_agent(user)
      result
  end

  def get(id) do
    Database.get(Post, id)
  end

  def get(:user, author_id) do
    Database.get_by(:author, Post, author_id)
  end
  def get(:newest, limit) do
    Database.get_all(Post, limit)
  end

  def exists?(id), do: get(id) !== nil

end
