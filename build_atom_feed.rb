require "open-uri"
require "json"
require "rss"
require "cgi"

# YURI_TAG_ID = -"a3c67850-4684-404e-9b7f-c69850ee5da6"
BASE_CHAPTER_URL = -"https://api.mangadex.org/chapter"
BASE_MANGA_URL = -"https://api.mangadex.org/manga"

CHAPTER_QUERY_STRING = %w[
  includeEmptyPages=0
  includeExternalUrl=0
  includeFuturePublishAt=0
  includeFutureUpdates=0
  includes[]=manga
  includes[]=scanlation_group
  limit=100
  order[readableAt]=desc
  translatedLanguage[]=vi
  translatedLanguage[]=en
  contentRating[]=safe
  contentRating[]=suggestive
  contentRating[]=erotica
  contentRating[]=pornographic
  offset=%s
].join("&")

manga_ids = []
authors = {}
artists = {}
cover_arts = {}
chapters = []

[0, 100, 200].each do |offset|
  # Fetch a list of chapters
  chapters_url = format("#{BASE_CHAPTER_URL}?#{CHAPTER_QUERY_STRING}", offset)
  chapters += JSON.parse(URI.parse(chapters_url).open.read)["data"].map do |chapter|
    manga = chapter["relationships"].detect { |relationship| relationship["type"] == "manga" }
    manga_ids << manga["id"]
    chapter
  end
end

# pp chapters
# pp manga_ids

# Fetch a list of mangas for additional metadata (author, artist, cover art)
manga_ids.uniq!  # Remove duplicate IDs
batch_size = 50  # Adjust this number as needed

manga_ids.each_slice(batch_size) do |batch_ids|
  # Fetch a list of mangas for additional metadata (author, artist, cover art)
  mangas_query_string = (
    %w[
      includes[]=cover_art
      includes[]=author
      includes[]=artist
      contentRating[]=safe
      contentRating[]=suggestive
      contentRating[]=erotica
      contentRating[]=pornographic
      limit=100
    ] +
    batch_ids.map { |manga_id| "ids[]=#{manga_id}" }
  ).join("&")
  
  mangas_url = "#{BASE_MANGA_URL}?#{mangas_query_string}"
  
  JSON.parse(URI.parse(mangas_url).open.read)["data"].each do |manga|
    manga["relationships"].each do |relationship|
      case relationship["type"]
      when "author"
        authors[manga["id"]] ||= []
        authors[manga["id"]] << relationship
      when "artist"
        artists[manga["id"]] ||= []
        artists[manga["id"]] << relationship
      when "cover_art"
        cover_arts[manga["id"]] ||= []
        cover_arts[manga["id"]] << relationship
      end
    end
  end

  # Add a small delay to avoid rate limiting
  sleep 0.5
end

# pp authors
# pp artists
# pp cover_arts

# Bail out if there's no chapters
exit if chapters.empty?

# Build actual feed
atom = RSS::Maker.make("atom") do |maker|
  maker.channel.authors.new_author do |author|
    author.name = "Latest chapters from MangaDex"
    author.uri = "https://github.com/TNTKien/rss"
  end

  maker.channel.id = "https://dev.suicaodex.com"
  maker.channel.title = "Latest Chapters from MangaDex"
  maker.channel.updated = chapters.first["attributes"]["updatedAt"]

  chapters.each do |chapter|
    manga = chapter["relationships"].detect { |relationship| relationship["type"] == "manga" }

    manga_title = manga["attributes"]["title"].first[1]
    title = manga_title.dup
    title << " Vol.#{chapter['attributes']['volume']}" if chapter["attributes"]["volume"]
    title << " Ch.#{chapter['attributes']['chapter']}" if chapter["attributes"]["chapter"]
    title << " #{chapter['attributes']['title']}" if chapter["attributes"]["title"]

    cover_art = %W[
      https://api.suicaodex.com/covers/
      #{manga['id']}/
      #{cover_arts[manga['id']][0]['attributes']['fileName']}.256.jpg
    ].join

    scanlation_groups = chapter["relationships"].filter_map do |relationship|
      next unless relationship["type"] == "scanlation_group"

      %(<a href="https://dev.suicaodex.com/group/#{relationship['id']}">#{CGI.escapeHTML(relationship['attributes']['name'])}</a>)
    end.join(", ")

    tags = manga["attributes"]["tags"].map do |tag|
      %(<a href="https://mangadex.org/tag/#{tag['id']}">#{CGI.escapeHTML(tag['attributes']['name']['en'])}</a>)
    end

    content_rating = manga["attributes"]["contentRating"]
    if content_rating != "safe"
      tags.unshift %(<a href="https://mangadex.org/titles?content=#{content_rating}"><strong>#{content_rating.upcase}</strong></a>)
    end

    tags = tags.join(", ")

    maker.items.new_item do |item|
      item.id = "https://dev.suicaodex.com/chapter/#{chapter['id']}"
      item.title = title
      item.link = item.id
      item.updated = chapter["attributes"]["updatedAt"]

      if authors[manga["id"]]&.map { _1["id"] } == artists[manga["id"]]&.map { _1["id"] }
        authors[manga["id"]].each do |author|
          item.authors.new_author do |author_item|
            author_item.name = CGI.escapeHTML(author["attributes"]["name"])
            author_item.uri = "https://dev.suicaodex.com/author/#{author['id']}"
          end
        end
      else
        authors[manga["id"]]&.each do |author|
          item.authors.new_author do |author_item|
            author_item.name = "#{CGI.escapeHTML(author['attributes']['name'])} (Author)"
            author_item.uri = "https://dev.suicaodex.com/author/#{author['id']}"
          end
        end

        artists[manga["id"]]&.each do |artist|
          item.authors.new_author do |artist_item|
            artist_item.name = "#{CGI.escapeHTML(artist['attributes']['name'])} (Artist)"
            artist_item.uri = "https://dev.suicaodex.com/author/#{artist['id']}"
          end
        end
      end

      item.content.content = <<~HTML.strip
        <p>
          <img src="#{cover_art}"/>
        </p>
        <p>
          <strong>Title:</strong>
          <a href="https://dev.suicaodex.com/manga/#{manga['id']}">#{manga_title}</a>
        </p>
        <p>
          <strong>Group:</strong>
          #{scanlation_groups || '<em>No Group</em>'}
        </p>
        <p>
          <strong>Tags:</strong>
          #{tags}
        </p>
      HTML
    end
  end
end

puts atom
