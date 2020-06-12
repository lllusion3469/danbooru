class PoolVersion < ApplicationRecord
  belongs_to :updater, :class_name => "User"
  belongs_to :pool

  self.record_timestamps = false

  def self.enabled?
    true
  end

  def self.database_url
    ENV["ARCHIVE_DATABASE_URL"] || "archive_#{Rails.env}".to_sym
  end

  establish_connection database_url if enabled?

  module SearchMethods
    def default_order
      order(updated_at: :desc)
    end

    def for_user(user_id)
      where("updater_id = ?", user_id)
    end

    def for_post_id(post_id)
      where_array_includes_any(:added_post_ids, [post_id]).or(where_array_includes_any(:removed_post_ids, [post_id]))
    end

    def name_matches(name)
      name = normalize_name_for_search(name)
      name = "*#{name}*" unless name =~ /\*/
      where_ilike(:name, name)
    end

    def search(params)
      q = super
      q = q.search_attributes(params, :pool_id, :post_ids, :added_post_ids, :removed_post_ids, :updater_id, :description, :description_changed, :name, :name_changed, :version, :is_active, :is_deleted, :category)

      if params[:post_id]
        q = q.for_post_id(params[:post_id].to_i)
      end

      if params[:name_matches].present?
        q = q.name_matches(params[:name_matches])
      end

      if params[:updater_name].present?
        q = q.where(updater_id: User.name_to_id(params[:updater_name]))
      end

      if params[:is_new].to_s.truthy?
        q = q.where(version: 1)
      elsif params[:is_new].to_s.falsy?
        q = q.where("version != 1")
      end

      q.apply_default_order(params)
    end
  end

  extend SearchMethods

  def self.sqs_service
    SqsService.new(Danbooru.config.aws_sqs_archives_url)
  end

  def self.queue(pool, updater, updater_ip_addr)
    # queue updates to sqs so that if archives goes down for whatever reason it won't
    # block pool updates
    raise NotImplementedError.new("Archive service is not configured.") if !enabled?

    json = {
      pool_id: pool.id,
      post_ids: pool.post_ids,
      updater_id: updater.id,
      updater_ip_addr: updater_ip_addr.to_s,
      created_at: pool.created_at.try(:iso8601),
      updated_at: pool.updated_at.try(:iso8601),
      description: pool.description,
      name: pool.name,
      is_active: pool.is_active?,
      is_deleted: pool.is_deleted?,
      category: pool.category
    }
    if Danbooru.config.aws_sqs_archives_url.present?
      msg = "add pool version\n#{json.to_json}"
      sqs_service.send_message(msg, message_group_id: "pool:#{pool.id}")
    else
      PoolVersion.create_from_json(json.with_indifferent_access)
    end
  end

  def self.normalize_name(name)
    name.gsub(/[_[:space:]]+/, "_").gsub(/\A_|_\z/, "")
  end

  def self.normalize_name_for_search(name)
    normalize_name(name).mb_chars.downcase
  end

  def previous
    @previous ||= begin
      PoolVersion.where("pool_id = ? and version < ?", pool_id, version).order("version desc").limit(1).to_a
    end
    @previous.first
  end

  def subsequent
    @subsequent ||= begin
      PoolVersion.where("pool_id = ? and version > ?", pool_id, version).order("version asc").limit(1).to_a
    end
    @subsequent.first
  end

  def current
    @current ||= begin
      PoolVersion.where("pool_id = ?", pool_id).order("version desc").limit(1).to_a
    end
    @current.first
  end

  def self.status_fields
    {
      posts_changed: "Posts",
      name: "Renamed",
      description: "Description",
      was_deleted: "Deleted",
      was_undeleted: "Undeleted",
      was_activated: "Activated",
      was_deactivated: "Deactivated",
    }
  end

  def posts_changed(type)
    other = self.send(type)
    ((post_ids - other.post_ids) | (other.post_ids - post_ids)).length.positive?
  end

  def was_deleted(type)
    other = self.send(type)
    if type == "previous"
      is_deleted && !other.is_deleted
    else
      !is_deleted && other.is_deleted
    end
  end

  def was_undeleted(type)
    other = self.send(type)
    if type == "previous"
      !is_deleted && other.is_deleted
    else
      is_deleted && !other.is_deleted
    end
  end

  def was_activated(type)
    other = self.send(type)
    if type == "previous"
      is_active && !other.is_active
    else
      !is_active && other.is_active
    end
  end

  def was_deactivated(type)
    other = self.send(type)
    if type == "previous"
      !is_active && other.is_active
    else
      is_active && !other.is_active
    end
  end

  def pretty_name
    name.tr("_", " ")
  end

  def self.find_previous(pool_id, updated_at)
    PoolVersion.where(pool_id: pool_id).where("updated_at < ?", updated_at).order("id desc").first
  end

  def self.calculate_version(pool_id, updated_at)
    1 + where("pool_id = ?", pool_id).maximum(:version).to_i
  end

  def self.create_from_json(json)
    created_at = json["created_at"] ? Time.parse(json["created_at"]) : nil
    updated_at = json["updated_at"] ? Time.parse(json["updated_at"]) : created_at
    post_ids = json["post_ids"]
    previous = find_previous(json["pool_id"], updated_at)
    subject = PoolVersion.new
    subject.version = calculate_version(json["pool_id"], updated_at)

    if previous && previous.updater_id == json["updater_id"] && updated_at - previous.updated_at < 1.hour
      subject = previous
      previous = find_previous(previous.pool_id, previous.updated_at)
    end

    if previous
      added_post_ids = post_ids - previous.post_ids
      removed_post_ids = previous.post_ids - post_ids
    else
      added_post_ids = post_ids
      removed_post_ids = []
    end

    description_changed = previous.nil? || json["description"] != previous.try(:description)
    name_changed = previous.nil? || json["name"] != previous.try(:name)
    attribs = {
      pool_id: json["pool_id"],
      post_ids: post_ids,
      added_post_ids: added_post_ids,
      removed_post_ids: removed_post_ids,
      updater_id: json["updater_id"],
      updater_ip_addr: json["updater_ip_addr"],
      description: json["description"],
      description_changed: description_changed,
      name: json["name"],
      name_changed: name_changed,
      created_at: created_at,
      updated_at: updated_at,
      is_active: json["is_active"],
      is_deleted: json["is_deleted"],
      category: json["category"]
    }

    subject.attributes = attribs
    subject.id = json["id"] if json["id"]
    subject.save
  end

  def self.available_includes
    [:updater, :pool]
  end
end
