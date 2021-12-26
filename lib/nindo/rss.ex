defmodule Nindo.RSS do
  @moduledoc """
    Parse and generate RSS feeds
  """

  alias NinDB.{Source}
  alias Nindo.{Accounts, Posts, Post, Format, RSS.YouTube}

  import Nindo.Core

  @default_feed %{"items" => []}

  # Methods to parse feeds

  @doc """
    Detect XML feed location from base URI

    When getting a base URI (without https or http) and a feed type, detect XML feed location.

    Notice: Atom and YouTube feeds will be converted to RSS using [Atom2Rss](https://feedmix.novaclic.com/atom2rss.php). See `atom_to_rss()` for more info.

  ## Available types

    - Blogger
    - Wordpress
    - YouTube (channel)
    - Atom
    - Direct link

  ## Examples

      iex> Nindo.RSS.detect_feed("blogger", "webdevelopment-en-meer.blogspot.com")
      "https://webdevelopment-en-meer.blogspot.com/feeds/posts/default?alt=rss&max-results=5"

      iex> Nindo.RSS.detect_feed("wordpress", "www.duurzamemaassluizers.nl")
      "https://www.duurzamemaassluizers.nl/feed/"

      iex> Nindo.RSS.detect_feed("youtube", "www.youtube.com/channel/UCx4li1iMygs5KtqgcU5KGRw")
      "https://feedmix.novaclic.com/atom2rss.php?source=https://www.youtube.com/feeds/videos.xml?channel_id=UCx4li1iMygs5KtqgcU5KGRw"
  """
  def detect_feed(type, url)
  def detect_feed("blogger", url),     do: "https://" <> url <> "/feeds/posts/default?alt=rss&max-results=5"
  def detect_feed("wordpress", url),   do: "https://" <> url <> "/feed/"
  def detect_feed("youtube", url) do
    [_, _, channel] = String.split(url, "/")
    atom_to_rss("https://www.youtube.com/feeds/videos.xml?channel_id=#{channel}")
  end
  def detect_feed("atom", url),        do: atom_to_rss("https://" <> url)
  def detect_feed(_, url),             do: "https://" <> url

  @doc """
    Detect favicon location

    Given a base URI as parameter, detect a favicon.

  ## Examples

      iex> Nindo.RSS.detect_favicon("geheimesite.nl")
      "https://geheimesite.nl/favicon.ico"
  """
  def detect_favicon(url) do
    "https://" <> url <> "/favicon.ico"
  end

  @doc """
    URI of the Nindo instance were using (root domain without protocol)
  """
  def base_url(), do: Application.get_env(:nindo, :base_url)

  @doc """
    Fetch and parse RSS feeds

    Given a base URI, detect a RSS feed using `detect_feed/2` and fetch it using `HTTPoison`. Then parse it using `FastRSS`. Returns a parsed feed.
  """
  def parse_feed(url, type) do
    url = detect_feed(type, url)
    case HTTPoison.get(url) do
      {:ok, %HTTPoison.Response{body: body}} ->
        case FastRSS.parse(body) do
          {:ok, feed} -> feed
          error -> error
        end
      error -> error
    end
  end

  @doc """
    Generate list of posts

    Given a parsed feed and source, generate a `Nindo.Post` struct that resembles a `NinDB.Post` struct for each item in the feed.

    Currently only returns first five posts to limit memory allocation issues in production.

    If no source is given, default to NinDB.Source{}
  """
  def generate_posts(feed, source \\ %Source{}) do
    feed["items"]
    |> Enum.take(5) # remove to get entire feed
    |> Enum.map(fn entry -> Task.async(fn ->
        id = :erlang.phash2(entry["title"])
        post = %Post{
          author: feed["title"],
          body: HtmlSanitizeEx.basic_html(entry["description"]),
          id: id,
          datetime: from_rfc822(entry["pub_date"]),
          image: entry["media"]["thumbnail"]["attrs"]["url"],
          title: entry["title"],
          link: entry["link"],
          type: source.type,
          source: source
        }
        Cachex.put(:rss, "#{source.id}:#{id}", post)
        post
      end)
    end)
    |> Task.await_many(30000)
  end

  @doc """
    Convert Atom to RSS

    Convert Atom feed to RSS feed using [Atom2Rss](https://feedmix.novaclic.com/atom2rss.php)
  """
  def atom_to_rss(source) do
    "https://feedmix.novaclic.com/atom2rss.php?source=" <> URI.encode(source)
  end

  # Methods to generate RSS feeds

  @doc """
    Generate RSS channel

    Given a user (`NinDB.Account`), generate a RSS channel.

    Used in `generate_feed/2`.
  """
  def generate_channel(user) do
    channel(
      "#{Format.display_name(user)}'s feed · Nindo",
      "https://#{base_url()}/user/#{user.username}",
      user.description
    )
  end

  @doc """
    Delegates to `RSS.channel/5`.
  """
  def channel(title, link, desc) do
    RSS.channel(
      title,
      link,
      desc,
      to_rfc822(datetime()),
      "en-us"
    )
  end

  @doc """
    Generate entries

    Given a user (`NinDB.Account`), generate a list of RSS items from their posts. Uses `generate_entry/4`.

    Used in `generate_feed/2`.
  """
  def generate_entries(user) do
    :user
    |> Posts.get(user.id)
    |> Enum.reverse()
    |> Enum.map(&generate_entry(&1.title, &1.body, &1.datetime, &1.id))
  end

  @doc """
    Generate a single RSS feed entrie.

    Given a title, body, datetime and post id, generate a RSS feed item.

    Used in `generate_entries/1`.
  """
  def generate_entry(title, body, datetime, id) do
    RSS.item(
      title,
      markdown(body),
      to_rfc822(datetime),
      "https://#{base_url()}/post/#{id}",
      "https://#{base_url()}/post/#{id}"
    )
  end

  @doc """
    Generate a RSS feed

    Given a RSS channel generated by `generate_channel/1` and a list of items generated by `generate_entries/1`, create a RSS feed using `RSS`.
  """
  defdelegate generate_feed(channel, items), to: RSS, as: :feed

  # Methods to generate Nindo feeds

  @doc """
    Fetch and parse posts for an user

    Used in FeedAgent to generate user feeds. Takes a tuple containing a username and the list of previous posts as an argument and returns a new tuple with the username and a new list of posts generated using sources and followed users from that account.

    It also caches the parsed feeds using Cachex with the URI as key.

  ## Parameters

    `{username, posts}`
  """
  def fetch_posts({username, _}) do
    account = Accounts.get_by(:username, username)

    rss_posts =
      account.sources
      |> Enum.map(fn source -> Task.async(fn ->

        feed = case parse_feed(source.feed, source.type) do
          {:error, _} -> @default_feed
          f -> f
        end

        Cachex.put(:rss, source.feed, feed)
        generate_posts(feed, source)

      end) end)
      |> Task.await_many(30000)
      |> List.flatten()

    user_posts =
      account.following
      |> Enum.map(fn username -> Task.async(fn ->

        account = Accounts.get_by(:username, username)
        posts = Posts.get(:user, account.id)

        Enum.map(posts, fn post ->
          Map.from_struct(post)
        end)

      end) end)
      |> Task.await_many(30000)
      |> List.flatten()

    posts =
      user_posts ++ rss_posts
      |> Enum.sort_by(&(&1.datetime), {:desc, NaiveDateTime})

    {username, posts}
  end

  @doc """
    Generate sources for database

    Given a parsed RSS feed, feed type and base URI, construct a map that can be stored in account schema under the feeds key and saved in the database.
  """
  def generate_source(title, type, url) do
    %Source{
      title: title,
      id: :erlang.phash2(url),
      feed: url,
      type: type,
      icon: detect_favicon(
        URI.parse("https://" <> URI.decode(url)).authority
      )
    }
  end

  # Methods to handle YT api stuff

  defmodule YouTube do
    @moduledoc false

    defp key() do
      System.get_env("YT_KEY")
    end

    @doc """
    Invidious instance to use for embeds and more.
    """
    def instance() do
      Application.get_env(:nindo, :invidious_instance)
    end

    @doc """
    Convert legacy channel URI or custom channel URI to the default format.
    """
    def to_channel_link(url) do
      [_, type, channel] = String.split(url, "/")

      channel_id =
        case type do
          "c" -> get_from_custom(url)
          "user" -> get_from_username(channel)
          _ -> channel
        end

      "www.youtube.com/channel/#{channel_id}"
    end

    defp get_from_custom(source) do
      data = parse_json("https://youtube.googleapis.com/youtube/v3/search?q=#{source}&part=id&type=channel&fields=items(id(kind,channelId))&max_results=1&key=#{key()}")
      hd(data["items"])["id"]["channelId"]
    end

    defp get_from_username(username) do
      data = parse_json("https://www.googleapis.com/youtube/v3/channels?forUsername=#{username}&part=id&key=#{key()}")
      hd(data["items"])["id"]
    end

    def parse_json(source) do
      case HTTPoison.get(source) do
        {:ok, %HTTPoison.Response{body: body}} ->
          case Jason.decode(body) do
            {:ok, data} -> data
            error -> error
          end
        error -> error
      end
    end

  end

end
