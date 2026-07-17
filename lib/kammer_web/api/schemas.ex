defmodule KammerWeb.Api.Schemas do
  @moduledoc """
  OpenAPI schemas for the JSON API (issue #30): these mirror
  `KammerWeb.Api.Serializer` field for field — the serializer is the
  wire truth, this is its published description. Two tests keep the
  two honest: `openapi_test.exs` (route coverage) and
  `schema_conformance_test.exs` (real responses validate against these
  schemas, issue #151).
  """

  alias OpenApiSpex.Schema

  defmodule Error do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Error",
      description: "The one error envelope: stable code, human message.",
      type: :object,
      properties: %{
        error: %Schema{
          type: :object,
          properties: %{
            code: %Schema{type: :string, example: "not_found"},
            message: %Schema{type: :string},
            details: %Schema{type: :object, nullable: true}
          },
          required: [:code, :message]
        }
      },
      required: [:error]
    })
  end

  defmodule Community do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Community",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        accent_color: %Schema{type: :string, description: "Hex theme color, e.g. #3E6B48"},
        default_locale: %Schema{type: :string, enum: ["en", "da"]},
        listed_on_instance: %Schema{type: :boolean},
        require_real_names: %Schema{type: :boolean},
        my_role: %Schema{
          type: :string,
          enum: ["owner", "admin", "member"],
          nullable: true,
          description:
            "The calling viewer's community role — null for non-members, " <>
              "and when the viewer's rights weren't resolved"
        },
        viewer_can: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: ["manage_community", "create_group", "view_member_directory"]
          },
          description:
            "Actions the calling viewer may take on this community (issue " <>
              "#199) — advisory, so clients hide controls the viewer lacks; " <>
              "the server still enforces. Empty when the viewer's rights " <>
              "weren't resolved (e.g. an embedded community reference)."
        }
      },
      required: [
        :id,
        :name,
        :slug,
        :accent_color,
        :default_locale,
        :listed_on_instance,
        :require_real_names,
        :viewer_can
      ]
    })
  end

  defmodule CommunityParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CommunityParams",
      description: "Editable community settings (issue #183). All fields optional on update.",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        accent_color: %Schema{type: :string},
        default_locale: %Schema{type: :string, enum: ["en", "da"]},
        listed_on_instance: %Schema{type: :boolean},
        require_real_names: %Schema{type: :boolean}
      }
    })
  end

  defmodule Group do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Group",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        visibility: %Schema{
          type: :string,
          enum: ["private", "community", "public_link", "public_listed"]
        },
        join_policy: %Schema{
          type: :string,
          enum: ["invite_only", "request_approval", "open"]
        },
        posting_policy: %Schema{
          type: :string,
          enum: ["all_members", "admins_only"],
          description:
            "Who may post (issue #259). Manager-only: present exactly when " <>
              "`viewer_can` includes `manage_group`, so it never rides the " <>
              "tokenless public group shape."
        },
        comment_policy: %Schema{
          type: :string,
          enum: ["members", "members_and_guests", "off"],
          description: "Who may comment (issue #259). Manager-only (see `posting_policy`)."
        },
        approval_queue: %Schema{
          type: :boolean,
          description:
            "Whether new posts wait in a moderation queue before they appear " <>
              "(SPEC §3). Manager-only (see `posting_policy`)."
        },
        version_retention: %Schema{
          type: :integer,
          nullable: true,
          description:
            "How many prior file versions the group keeps (ADR 0017); null means " <>
              "the instance default. Manager-only (see `posting_policy`)."
        },
        features: %Schema{type: :array, items: %Schema{type: :string}},
        sealed: %Schema{type: :boolean},
        archived: %Schema{type: :boolean},
        my_role: %Schema{
          type: :string,
          enum: ["owner", "admin", "member"],
          nullable: true,
          description:
            "The calling viewer's group role — null for non-members, and " <>
              "when the viewer's rights weren't resolved"
        },
        viewer_can: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: [
              "join",
              "request_to_join",
              "post",
              "moderate",
              "manage_group",
              "manage_members",
              "delete_group",
              "create_event",
              "upload_file"
            ]
          },
          description:
            "Actions the calling viewer may take in this group (issue " <>
              "#199) — advisory, so clients hide controls the viewer lacks; " <>
              "the server still enforces. `create_event`/`upload_file` also " <>
              "reflect the group's feature toggles. Empty when the viewer's " <>
              "rights weren't resolved."
        },
        guest_rsvp_allowed: %Schema{
          type: :boolean,
          description: "Whether an account-less guest may RSVP to this group's events (SPEC §6)"
        },
        guest_comment_allowed: %Schema{
          type: :boolean,
          description: "Whether an account-less guest may comment on this group's posts (SPEC §3)"
        },
        guest_subscribe_allowed: %Schema{
          type: :boolean,
          description: "Whether an account-less guest may subscribe to this group's feed by email"
        }
      },
      required: [
        :id,
        :name,
        :slug,
        :visibility,
        :join_policy,
        :features,
        :sealed,
        :archived,
        :viewer_can,
        :guest_rsvp_allowed,
        :guest_comment_allowed,
        :guest_subscribe_allowed
      ]
    })
  end

  defmodule PublicCommunity do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PublicCommunity",
      description:
        "The tokenless public community read (issue #185 slice B): the " <>
          "community's public face plus its `public_listed` groups — the " <>
          "same content `CommunityLive.Home` shows an anonymous visitor. " <>
          "`public_link` groups are reachable directly by slug (the group " <>
          "show endpoint) but stay out of this list, same as the LiveView " <>
          "page — that's what \"unlisted\" means.",
      type: :object,
      properties: %{
        community: Community,
        groups: %Schema{type: :array, items: Group}
      },
      required: [:community, :groups]
    })
  end

  defmodule Author do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Author",
      type: :object,
      nullable: true,
      properties: %{
        type: %Schema{type: :string, enum: ["user", "group", "guest"]},
        id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string}
      },
      required: [:type, :id, :display_name]
    })
  end

  defmodule Comment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Comment",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        parent_comment_id: %Schema{type: :string, format: :uuid, nullable: true},
        author: Author,
        body_markdown: %Schema{type: :string, nullable: true},
        deleted: %Schema{type: :boolean},
        pending_approval: %Schema{
          type: :boolean,
          description: "Guest comments awaiting moderation — visible to moderators only"
        },
        inserted_at: %Schema{type: :string, format: :"date-time"},
        edited_at: %Schema{type: :string, format: :"date-time", nullable: true},
        reactions: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :integer},
          description: "Emoji → count"
        },
        my_reactions: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Emoji the caller has reacted with"
        }
      },
      required: [:id, :deleted, :pending_approval, :inserted_at, :reactions, :my_reactions]
    })
  end

  defmodule Poll do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Poll",
      type: :object,
      nullable: true,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        multiple_choice: %Schema{type: :boolean},
        anonymous: %Schema{type: :boolean},
        closes_at: %Schema{type: :string, format: :"date-time", nullable: true},
        my_votes: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid},
          description: "Option ids the caller currently votes for"
        },
        options: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              text: %Schema{type: :string},
              votes: %Schema{type: :integer}
            },
            required: [:id, :text, :votes]
          }
        }
      },
      required: [:id, :multiple_choice, :anonymous, :my_votes, :options]
    })
  end

  defmodule PollParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PollParams",
      description:
        "A poll to create with a post. The post body is the question; " <>
          "options keep the order they are sent in.",
      type: :object,
      nullable: true,
      properties: %{
        multiple_choice: %Schema{type: :boolean, nullable: true},
        anonymous: %Schema{type: :boolean, nullable: true},
        closes_at: %Schema{type: :string, format: :"date-time", nullable: true},
        options: %Schema{
          type: :array,
          minItems: 2,
          items: %Schema{
            type: :object,
            properties: %{text: %Schema{type: :string}},
            required: [:text]
          }
        }
      },
      required: [:options]
    })
  end

  defmodule StoredFile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StoredFile",
      description:
        "An uploaded file. `id` is what create-post's `stored_file_ids` " <>
          "takes; the URLs are Bearer-authorized API routes.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        filename: %Schema{type: :string},
        content_type: %Schema{type: :string},
        byte_size: %Schema{type: :integer},
        kind: %Schema{type: :string, enum: ["image", "file"]},
        width: %Schema{type: :integer, nullable: true},
        height: %Schema{type: :integer, nullable: true},
        url: %Schema{type: :string},
        thumbnail_url: %Schema{type: :string, nullable: true},
        download_url: %Schema{type: :string}
      },
      required: [:id, :filename, :content_type, :byte_size, :kind, :url, :download_url]
    })
  end

  defmodule Folder do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Folder",
      description:
        "A file-space folder (ADR 0009). Overrides can only restrict, " <>
          "never widen; `system` folders (e.g. Feed uploads) can't be " <>
          "renamed or deleted.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        parent_folder_id: %Schema{type: :string, format: :uuid, nullable: true},
        read_override: %Schema{type: :string, enum: ["inherit", "admins_only"]},
        write_override: %Schema{type: :string, enum: ["inherit", "admins_only"]},
        system: %Schema{type: :boolean}
      },
      required: [:id, :name, :read_override, :write_override, :system]
    })
  end

  defmodule FileVersion do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "FileVersion",
      description: "One stored version of a file entry (ADR 0017), newest first.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        filename: %Schema{type: :string},
        content_type: %Schema{type: :string},
        byte_size: %Schema{type: :integer},
        kind: %Schema{type: :string, enum: ["image", "file"]},
        version_seq: %Schema{type: :integer},
        uploaded_at: %Schema{type: :string, format: :"date-time"},
        uploaded_by: Author,
        mine: %Schema{type: :boolean, description: "Uploaded by the caller"},
        current: %Schema{type: :boolean, description: "The version the entry points at"},
        url: %Schema{type: :string},
        thumbnail_url: %Schema{type: :string, nullable: true},
        download_url: %Schema{type: :string}
      },
      required: [
        :id,
        :filename,
        :content_type,
        :byte_size,
        :kind,
        :version_seq,
        :uploaded_at,
        :mine,
        :current,
        :url,
        :download_url
      ]
    })
  end

  defmodule LibraryFile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "File",
      description:
        "A library file entry (ADR 0017): its current version's bytes " <>
          "plus placement and history. `versions` is present on detail, " <>
          "empty on listings; `mine` marks the caller's own upload.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        file_entry_id: %Schema{type: :string, format: :uuid, nullable: true},
        folder_id: %Schema{type: :string, format: :uuid, nullable: true},
        filename: %Schema{type: :string},
        content_type: %Schema{type: :string},
        byte_size: %Schema{type: :integer},
        kind: %Schema{type: :string, enum: ["image", "file"]},
        width: %Schema{type: :integer, nullable: true},
        height: %Schema{type: :integer, nullable: true},
        version_seq: %Schema{type: :integer, nullable: true},
        uploaded_at: %Schema{type: :string, format: :"date-time", nullable: true},
        uploaded_by: Author,
        mine: %Schema{type: :boolean},
        url: %Schema{type: :string},
        thumbnail_url: %Schema{type: :string, nullable: true},
        download_url: %Schema{type: :string},
        versions: %Schema{type: :array, items: FileVersion}
      },
      required: [
        :id,
        :filename,
        :content_type,
        :byte_size,
        :kind,
        :mine,
        :url,
        :download_url,
        :versions
      ]
    })
  end

  defmodule FileListing do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "FileListing",
      description:
        "One folder's contents: its subfolders and files, the breadcrumb " <>
          "chain (root-first, inclusive), and the caller's write/manage " <>
          "capabilities here (advisory — the context still enforces).",
      type: :object,
      properties: %{
        folder: %Schema{oneOf: [Folder], nullable: true, description: "null at the space root"},
        chain: %Schema{type: :array, items: Folder},
        folders: %Schema{type: :array, items: Folder},
        files: %Schema{type: :array, items: LibraryFile},
        can_write: %Schema{type: :boolean},
        can_manage: %Schema{type: :boolean}
      },
      required: [:chain, :folders, :files, :can_write, :can_manage]
    })
  end

  defmodule Attachment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Attachment",
      description: "A stored file attached to a post, in display order.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        stored_file_id: %Schema{type: :string, format: :uuid},
        position: %Schema{type: :integer},
        filename: %Schema{type: :string},
        content_type: %Schema{type: :string},
        byte_size: %Schema{type: :integer},
        kind: %Schema{type: :string, enum: ["image", "file"]},
        width: %Schema{type: :integer, nullable: true},
        height: %Schema{type: :integer, nullable: true},
        url: %Schema{type: :string},
        thumbnail_url: %Schema{type: :string, nullable: true},
        download_url: %Schema{type: :string}
      },
      required: [
        :id,
        :stored_file_id,
        :position,
        :filename,
        :content_type,
        :byte_size,
        :kind,
        :url,
        :download_url
      ]
    })
  end

  defmodule Post do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Post",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        author: Author,
        body_markdown: %Schema{type: :string, nullable: true},
        deleted: %Schema{type: :boolean},
        published_at: %Schema{type: :string, format: :"date-time"},
        edited_at: %Schema{type: :string, format: :"date-time", nullable: true},
        pending_approval: %Schema{
          type: :boolean,
          description:
            "Awaiting moderation (approval-queue groups) — visible only to the author and moderators"
        },
        pinned: %Schema{type: :boolean},
        acknowledgment_required: %Schema{type: :boolean},
        acknowledged_count: %Schema{type: :integer},
        my_acknowledged: %Schema{
          type: :boolean,
          description: "Whether the caller has acknowledged this post"
        },
        comment_count: %Schema{type: :integer, nullable: true},
        reactions: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :integer},
          description: "Emoji → count"
        },
        my_reactions: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "Emoji the caller has reacted with"
        },
        attachments: %Schema{type: :array, items: Attachment},
        poll: Poll,
        viewer_can: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: ["edit", "delete", "pin", "moderate"]
          },
          description:
            "Actions the calling viewer may take on this post (issue " <>
              "#199) — advisory, so clients hide controls the viewer lacks; " <>
              "the server still enforces. `edit`/`delete` are the author's; " <>
              "`pin`/`moderate` are a moderator's. Empty when the viewer's " <>
              "rights weren't resolved."
        },
        comments: %Schema{type: :array, items: Comment}
      },
      required: [
        :id,
        :group_id,
        :deleted,
        :published_at,
        :pending_approval,
        :pinned,
        :acknowledgment_required,
        :acknowledged_count,
        :my_acknowledged,
        :reactions,
        :my_reactions,
        :attachments,
        :viewer_can
      ]
    })
  end

  defmodule Event do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Event",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        group: %Schema{
          type: :object,
          nullable: true,
          description: "The host group's summary, for provenance without a second fetch",
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            slug: %Schema{type: :string}
          },
          required: [:id, :name, :slug]
        },
        series_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Set when this event is one occurrence of a recurring series (ADR 0019)"
        },
        title: %Schema{type: :string},
        description_markdown: %Schema{type: :string, nullable: true},
        starts_at: %Schema{type: :string, format: :"date-time"},
        ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
        all_day: %Schema{type: :boolean},
        timezone: %Schema{type: :string},
        location_name: %Schema{type: :string, nullable: true},
        location_url: %Schema{type: :string, nullable: true},
        cancelled: %Schema{
          type: :boolean,
          description: "A cancelled occurrence stays viewable but leaves listings and feeds"
        },
        comments_locked: %Schema{type: :boolean},
        capacity: %Schema{
          type: :integer,
          nullable: true,
          description:
            "Cap on attending RSVPs (issue #318) — members and confirmed guests " <>
              "under one cap; null means unlimited. Beyond it, yes answers waitlist."
        },
        rsvp_counts: %Schema{
          type: :object,
          properties: %{
            yes: %Schema{type: :integer, description: "The attending count capacity caps"},
            maybe: %Schema{type: :integer},
            no: %Schema{type: :integer},
            waitlisted: %Schema{type: :integer}
          },
          required: [:yes, :maybe, :no, :waitlisted]
        },
        my_rsvp: %Schema{
          type: :string,
          enum: ["yes", "no", "maybe", "waitlisted"],
          nullable: true
        },
        waitlist_position: %Schema{
          type: :integer,
          nullable: true,
          description: "The caller's 1-based spot in the queue — set only while waitlisted"
        },
        waitlist: %Schema{
          type: :array,
          description:
            "The ordered waitlist — member-visible (SPEC §6): present on " <>
              "the event detail for host-group members; empty on lists, " <>
              "for authenticated non-members, and on the public (tokenless) " <>
              "event read, which get counts and capacity but no queued identities",
          items: %Schema{
            type: :object,
            properties: %{
              position: %Schema{type: :integer},
              attendee: Author
            },
            required: [:position]
          }
        },
        slots: %Schema{
          type: :array,
          description: "Volunteer signup slots — present on event detail, empty on lists",
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              title: %Schema{type: :string},
              capacity: %Schema{type: :integer},
              taken: %Schema{type: :integer},
              claimants: %Schema{type: :array, items: Author}
            },
            required: [:id, :title, :capacity, :taken]
          }
        },
        comments: %Schema{
          type: :array,
          description: "Present on event detail, empty on lists",
          items: Comment
        }
      },
      required: [
        :id,
        :group_id,
        :title,
        :starts_at,
        :all_day,
        :timezone,
        :cancelled,
        :comments_locked,
        :capacity,
        :rsvp_counts,
        :my_rsvp,
        :waitlist_position,
        :waitlist,
        :slots,
        :comments
      ]
    })
  end

  defmodule EventParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EventParams",
      description:
        "Create or edit an event. On create, an optional `recurrence` " <>
          "object materializes a series (ADR 0019) and the response is the " <>
          "first occurrence carrying its series_id. On edit, changes apply " <>
          "to this occurrence only.",
      type: :object,
      properties: %{
        title: %Schema{type: :string},
        description_markdown: %Schema{type: :string, nullable: true},
        starts_at: %Schema{type: :string, format: :"date-time"},
        ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
        all_day: %Schema{type: :boolean, nullable: true},
        timezone: %Schema{type: :string, nullable: true},
        location_name: %Schema{type: :string, nullable: true},
        location_url: %Schema{type: :string, nullable: true},
        capacity: %Schema{
          type: :integer,
          minimum: 1,
          nullable: true,
          description:
            "Cap on attending RSVPs (issue #318); null/absent means unlimited. " <>
              "Raising it promotes from the waitlist; lowering never demotes."
        },
        recurrence: %Schema{
          type: :object,
          nullable: true,
          description: "Create only — turns the event into a bounded recurring series",
          properties: %{
            frequency: %Schema{type: :string, enum: ["weekly", "biweekly", "monthly"]},
            until: %Schema{
              type: :string,
              format: :date,
              description: "Last date the series may run"
            }
          },
          required: [:frequency, :until]
        }
      },
      required: [:title, :starts_at]
    })
  end

  defmodule Notification do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Notification",
      description:
        "An in-app notification. Navigate via community.slug + group.slug " <>
          "plus whichever of post_id/comment_id/event_id is set.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        kind: %Schema{
          type: :string,
          enum: [
            "post",
            "mention",
            "reply",
            "acknowledgment_required",
            "event_created",
            "event_reminder",
            "event_promoted"
          ]
        },
        read: %Schema{type: :boolean},
        read_at: %Schema{type: :string, format: :"date-time", nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        actor: Author,
        community: Community,
        group: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            slug: %Schema{type: :string}
          },
          required: [:id, :name, :slug]
        },
        post_id: %Schema{type: :string, format: :uuid, nullable: true},
        comment_id: %Schema{type: :string, format: :uuid, nullable: true},
        event_id: %Schema{type: :string, format: :uuid, nullable: true}
      },
      required: [:id, :kind, :read, :inserted_at]
    })
  end

  defmodule Instance do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Instance",
      type: :object,
      properties: %{
        instance_name: %Schema{type: :string},
        version: %Schema{type: :string},
        api_versions: %Schema{type: :array, items: %Schema{type: :string}},
        min_client_version: %Schema{
          type: :string,
          nullable: true,
          description:
            "Advisory SemVer floor for the native-app handshake (#203): " <>
              "clients below it should fence themselves — the server does " <>
              "not reject them. Null means any client is fine."
        },
        default_locale: %Schema{type: :string},
        can_create_community: %Schema{
          type: :boolean,
          description:
            "Whether the calling device's user may create a community on this " <>
              "instance (SPEC §3 policy: operators only / any user). False for " <>
              "the tokenless capability probe — a client gates its \"new " <>
              "community\" entry point on this rather than assuming the policy."
        },
        instance_operator: %Schema{
          type: :boolean,
          description:
            "Whether the calling device's user operates this instance " <>
              "(issue #259) — per-viewer like can_create_community, false for " <>
              "the tokenless probe. Clients gate their operator surfaces " <>
              "(instance settings/moderation, legal editing) on this instead " <>
              "of probing an operator-only endpoint for the 403."
        },
        features: %Schema{
          type: :object,
          properties: %{
            guest_rsvp: %Schema{type: :boolean},
            web_push: %Schema{type: :boolean},
            vapid_public_key: %Schema{
              type: :string,
              nullable: true,
              description:
                "Raw VAPID public key for PushManager.subscribe; null when web_push is false (issue #251)."
            },
            registration: %Schema{type: :string, enum: ["open", "web_only"]}
          },
          required: [:guest_rsvp, :web_push, :vapid_public_key, :registration]
        }
      },
      required: [
        :instance_name,
        :version,
        :api_versions,
        :min_client_version,
        :default_locale,
        :can_create_community,
        :instance_operator,
        :features
      ]
    })
  end

  defmodule AuthUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthUser",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string, format: :email},
        display_name: %Schema{type: :string, nullable: true}
      },
      required: [:id, :email, :display_name]
    })
  end

  defmodule AuthRegisterResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthRegisterResponse",
      type: :object,
      properties: %{
        status: %Schema{type: :string, enum: ["confirmation_sent"]},
        user: AuthUser
      },
      required: [:status, :user]
    })
  end

  defmodule AuthExchangeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuthExchangeResponse",
      type: :object,
      properties: %{
        device_token: %Schema{type: :string},
        user: AuthUser
      },
      required: [:device_token, :user]
    })
  end

  defmodule PasskeyChallengeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasskeyChallengeResponse",
      description:
        "WebAuthn assertion options (ADR 0018, usernameless): feed `challenge` and " <>
          "`rp_id` to navigator.credentials.get, then send the assertion together " <>
          "with `challenge_token` (opaque, short-lived) to the verify operation.",
      type: :object,
      properties: %{
        challenge: %Schema{type: :string, description: "base64url, no padding"},
        rp_id: %Schema{type: :string},
        challenge_token: %Schema{type: :string}
      },
      required: [:challenge, :rp_id, :challenge_token]
    })
  end

  defmodule StepUpPasskeyChallenge do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StepUpPasskeyChallenge",
      description:
        "WebAuthn assertion options for a step-up (issue #294, ADR 0029): like " <>
          "the sign-in challenge, but for an already-authenticated caller — " <>
          "`allow_credentials` lists the caller's own registered credential ids " <>
          "(base64url, no padding) so the browser only offers passkeys that can " <>
          "succeed. Empty when the account has no passkeys; use the emailed " <>
          "step-up link instead.",
      type: :object,
      properties: %{
        challenge: %Schema{type: :string, description: "base64url, no padding"},
        rp_id: %Schema{type: :string},
        challenge_token: %Schema{type: :string},
        allow_credentials: %Schema{
          type: :array,
          items: %Schema{type: :string, description: "base64url, no padding"}
        }
      },
      required: [:challenge, :rp_id, :challenge_token, :allow_credentials]
    })
  end

  defmodule StatusResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StatusResponse",
      type: :object,
      properties: %{status: %Schema{type: :string}},
      required: [:status]
    })
  end

  defmodule CalendarToken do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CalendarToken",
      type: :object,
      properties: %{
        token: %Schema{type: :string, description: "The secret iCal feed token"},
        url: %Schema{
          type: :string,
          format: :uri,
          description:
            "The ready-to-subscribe .ics feed URL (scheme-swap to webcal:// if desired)"
        }
      },
      required: [:token, :url]
    })
  end

  defmodule HomeGroupSummary do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HomeGroupSummary",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        name: %Schema{type: :string},
        slug: %Schema{type: :string}
      },
      required: [:id, :name, :slug]
    })
  end

  defmodule CustomField do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CustomField",
      description:
        "A community-defined profile field (ADR 0020) — the roster's " <>
          "columns and the profile form's inputs. `visibility` is who may " <>
          "see answers in the directory; the owner always sees and " <>
          "answers their own.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        label: %Schema{type: :string},
        field_type: %Schema{type: :string, enum: ["text", "single_select"]},
        options: %Schema{type: :array, items: %Schema{type: :string}},
        required: %Schema{type: :boolean},
        visibility: %Schema{type: :string, enum: ["members", "admins"]},
        position: %Schema{type: :integer}
      },
      required: [:id, :label, :field_type, :options, :required, :visibility, :position]
    })
  end

  defmodule CustomFieldParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CustomFieldParams",
      description:
        "A new custom profile field (issue #259). `field_type` and its " <>
          "`options` are fixed at creation — changing them after members " <>
          "answer would orphan values — but `label`, `visibility`, and " <>
          "`required` stay editable afterward via the update endpoint.",
      type: :object,
      properties: %{
        label: %Schema{type: :string},
        field_type: %Schema{type: :string, enum: ["text", "single_select"]},
        options: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "The choices — required (non-empty) for single_select, ignored for text"
        },
        visibility: %Schema{type: :string, enum: ["members", "admins"]},
        required: %Schema{type: :boolean}
      }
    })
  end

  defmodule MemberUser do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "MemberUser",
      description: "A member's public identity: name plus the opt-in bio and pronouns.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string},
        bio: %Schema{type: :string, nullable: true},
        pronouns: %Schema{type: :string, nullable: true}
      },
      required: [:id, :display_name]
    })
  end

  defmodule Member do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Member",
      description:
        "A member-directory row (SPEC §4). `contact` and " <>
          "`custom_field_values` are already redacted for the calling " <>
          "viewer's role (ADR 0020) — hidden fields simply don't appear.",
      type: :object,
      properties: %{
        user: MemberUser,
        role: %Schema{type: :string, enum: ["owner", "admin", "member"]},
        joined_at: %Schema{type: :string, format: :"date-time"},
        contact: %Schema{
          type: :object,
          description: "The visible contact fields: phone / email / note",
          properties: %{
            phone: %Schema{type: :string},
            email: %Schema{type: :string},
            note: %Schema{type: :string}
          }
        },
        custom_field_values: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description: "Field id → this member's visible answer"
        }
      },
      required: [:user, :role, :joined_at, :contact, :custom_field_values]
    })
  end

  defmodule GroupMember do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GroupMember",
      type: :object,
      properties: %{
        user: MemberUser,
        role: %Schema{type: :string, enum: ["owner", "admin", "member"]},
        joined_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:user, :role, :joined_at]
    })
  end

  defmodule JoinRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "JoinRequest",
      description: "A pending request to join a request-approval group (SPEC §3).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        user: MemberUser,
        message: %Schema{type: :string, nullable: true},
        requested_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :user, :requested_at]
    })
  end

  defmodule Invite do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Invite",
      description:
        "An invite link as its managers see it (SPEC §3). `token` is the " <>
          "shareable secret — the web accept URL is /invite/{token}.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        token: %Schema{type: :string},
        group_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "Null for community-wide invites"
        },
        invited_email: %Schema{type: :string, nullable: true},
        expires_at: %Schema{type: :string, format: :"date-time", nullable: true},
        max_uses: %Schema{type: :integer, nullable: true},
        use_count: %Schema{type: :integer},
        revoked: %Schema{type: :boolean},
        created_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :token, :use_count, :revoked, :created_at]
    })
  end

  defmodule InvitePreview do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InvitePreview",
      description:
        "What an invite opens, before acceptance — the API twin of the " <>
          "public /invite/{token} landing page.",
      type: :object,
      properties: %{
        token: %Schema{type: :string},
        community: %Schema{
          type: :object,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            slug: %Schema{type: :string},
            description: %Schema{type: :string, nullable: true},
            require_real_names: %Schema{type: :boolean}
          },
          required: [:id, :name, :slug, :require_real_names]
        },
        group: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            name: %Schema{type: :string},
            slug: %Schema{type: :string}
          },
          required: [:id, :name, :slug]
        }
      },
      required: [:token, :community]
    })
  end

  defmodule InviteAcceptResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InviteAcceptResponse",
      description:
        "The joined target plus any required custom profile fields still " <>
          "unanswered — collect those next via the community profile " <>
          "operation (the API sibling of the complete-profile page).",
      type: :object,
      properties: %{
        community: Community,
        group: %Schema{oneOf: [Group], nullable: true},
        missing_required_fields: %Schema{type: :array, items: CustomField}
      },
      required: [:community, :missing_required_fields]
    })
  end

  defmodule Profile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Profile",
      description:
        "The caller's own account and base profile (SPEC §4) — contact " <>
          "visibilities included because it is theirs. Email changes go " <>
          "through the email-change confirmation round-trip (issue #258).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string, format: :email},
        display_name: %Schema{type: :string},
        locale: %Schema{type: :string},
        timezone: %Schema{type: :string},
        digest_frequency: %Schema{type: :string, enum: ["off", "daily", "weekly"]},
        feed_sort: %Schema{type: :string, enum: ["chronological", "activity"]},
        bio: %Schema{type: :string, nullable: true},
        pronouns: %Schema{type: :string, nullable: true},
        contact_phone: %Schema{type: :string, nullable: true},
        contact_phone_visibility: %Schema{type: :string, enum: ["hidden", "members", "admins"]},
        contact_email: %Schema{type: :string, nullable: true},
        contact_email_visibility: %Schema{type: :string, enum: ["hidden", "members", "admins"]},
        contact_note: %Schema{type: :string, nullable: true},
        contact_note_visibility: %Schema{type: :string, enum: ["hidden", "members", "admins"]}
      },
      required: [
        :id,
        :email,
        :display_name,
        :locale,
        :timezone,
        :digest_frequency,
        :feed_sort,
        :contact_phone_visibility,
        :contact_email_visibility,
        :contact_note_visibility
      ]
    })
  end

  defmodule CommunityProfile do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "CommunityProfile",
      description:
        "The caller's custom-field answers in one community (ADR 0020): " <>
          "every field the community defines, the caller's current values " <>
          "keyed by field id, and which required fields still need answers " <>
          "(a nag, never a lockout).",
      type: :object,
      properties: %{
        fields: %Schema{type: :array, items: CustomField},
        values: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :string},
          description: "Field id → the caller's answer"
        },
        missing_required_field_ids: %Schema{
          type: :array,
          items: %Schema{type: :string, format: :uuid}
        }
      },
      required: [:fields, :values, :missing_required_field_ids]
    })
  end

  defmodule Device do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Device",
      description:
        "A revocable credential (SPEC §2, issue #174): a browser session " <>
          "or a long-lived API device token. `device_name` is the user " <>
          "agent for sessions and the client-chosen name for API devices.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        kind: %Schema{type: :string, enum: ["session", "api_device"]},
        device_name: %Schema{type: :string, nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        current: %Schema{type: :boolean, description: "The credential making this request"}
      },
      required: [:id, :kind, :created_at, :current]
    })
  end

  defmodule Passkey do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Passkey",
      description:
        "A registered WebAuthn credential (ADR 0018, issue #260 port 5b) as its " <>
          "owner manages it. The credential material itself (credential id, public " <>
          "key) is never exposed — only the nickname and timestamps.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        nickname: %Schema{type: :string, nullable: true},
        created_at: %Schema{type: :string, format: :"date-time"},
        last_used_at: %Schema{type: :string, format: :"date-time", nullable: true}
      },
      required: [:id, :created_at]
    })
  end

  defmodule PasskeyRegistrationChallenge do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "PasskeyRegistrationChallenge",
      description:
        "WebAuthn registration options (ADR 0018, issue #260 port 5b): feed these to " <>
          "navigator.credentials.create, then send the attestation together with " <>
          "`challenge_token` (opaque, short-lived) to the create-passkey operation. " <>
          "`challenge`, `user_id`, and every id in `exclude_credentials` are " <>
          "base64url, no padding.",
      type: :object,
      properties: %{
        challenge: %Schema{type: :string, description: "base64url, no padding"},
        rp_id: %Schema{type: :string},
        challenge_token: %Schema{type: :string},
        user_id: %Schema{type: :string, description: "base64url, no padding"},
        user_name: %Schema{type: :string},
        user_display_name: %Schema{type: :string, nullable: true},
        exclude_credentials: %Schema{
          type: :array,
          items: %Schema{type: :string, description: "base64url, no padding"},
          description: "Already-registered credential ids, to prevent double-enrollment"
        }
      },
      required: [
        :challenge,
        :rp_id,
        :challenge_token,
        :user_id,
        :user_name,
        :user_display_name,
        :exclude_credentials
      ]
    })
  end

  defmodule NotificationLevel do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "NotificationLevel",
      description:
        "The caller's per-group notification level (SPEC §9). `level` is " <>
          "the effective one (the preference, or the group default when " <>
          "none is set); `default_level` is what the group defaults to.",
      type: :object,
      properties: %{
        level: %Schema{
          type: :string,
          enum: ["everything", "highlights", "mentions_only", "muted"]
        },
        default_level: %Schema{
          type: :string,
          enum: ["everything", "highlights", "mentions_only", "muted"]
        }
      },
      required: [:level, :default_level]
    })
  end

  defmodule HomeResponse do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "HomeResponse",
      description:
        "Upcoming events and recent activity across all the device owner's communities",
      type: :object,
      properties: %{
        upcoming_events: %Schema{
          type: :array,
          items: %Schema{
            allOf: [
              Event,
              %Schema{
                type: :object,
                properties: %{community: Community, group: HomeGroupSummary},
                required: [:community, :group]
              }
            ]
          }
        },
        recent_activity: %Schema{
          type: :array,
          items: %Schema{
            allOf: [
              Post,
              %Schema{
                type: :object,
                properties: %{community: Community, group: HomeGroupSummary},
                required: [:community, :group]
              }
            ]
          }
        }
      },
      required: [:upcoming_events, :recent_activity]
    })
  end

  defmodule GroupParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GroupParams",
      description:
        "Group settings (issue #183). On create, `sealed` may be set once " <>
          "and is irreversible (ADR 0005); it is never editable afterward.",
      type: :object,
      properties: %{
        name: %Schema{type: :string},
        slug: %Schema{type: :string},
        description: %Schema{type: :string, nullable: true},
        visibility: %Schema{
          type: :string,
          enum: ["private", "community", "public_link", "public_listed"]
        },
        join_policy: %Schema{type: :string, enum: ["invite_only", "request_approval", "open"]},
        posting_policy: %Schema{type: :string, enum: ["all_members", "admins_only"]},
        comment_policy: %Schema{type: :string, enum: ["members", "members_and_guests", "off"]},
        approval_queue: %Schema{type: :boolean},
        sealed: %Schema{type: :boolean, description: "Create-only, irreversible"},
        version_retention: %Schema{type: :integer, nullable: true}
      }
    })
  end

  defmodule GroupFeaturesParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GroupFeaturesParams",
      description: "The full set of enabled features (ADR 0016). The feed is always forced on.",
      type: :object,
      properties: %{
        features: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: ["feed", "events", "files", "availability", "assignments", "decisions"]
          }
        }
      },
      required: [:features]
    })
  end

  defmodule Report do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Report",
      description: "A reported post or comment in the moderation queue (issue #183).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        reason: %Schema{type: :string},
        status: %Schema{type: :string, enum: ["open", "dismissed", "resolved"]},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        reporter: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            display_name: %Schema{type: :string}
          }
        },
        subject: %Schema{
          type: :object,
          nullable: true,
          description: "The reported content, embedded for triage.",
          properties: %{
            type: %Schema{type: :string, enum: ["post", "comment"]},
            id: %Schema{type: :string, format: :uuid},
            group_id: %Schema{type: :string, format: :uuid, nullable: true},
            author: %Schema{type: :object, nullable: true},
            body_markdown: %Schema{type: :string, nullable: true}
          }
        }
      },
      required: [:id, :reason, :status, :inserted_at]
    })
  end

  defmodule ReportAction do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "ReportAction",
      description: "The report's new status after resolving or dismissing it.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        status: %Schema{type: :string, enum: ["dismissed", "resolved"]}
      },
      required: [:id, :status]
    })
  end

  defmodule Ban do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Ban",
      description:
        "An email ban (SPEC §11): community-level (issue #183) or " <>
          "instance-wide (issue #259) — the same wire shape either way.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        email: %Schema{type: :string},
        reason: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        banned_by: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            display_name: %Schema{type: :string}
          }
        }
      },
      required: [:id, :email, :inserted_at]
    })
  end

  defmodule BanParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "BanParams",
      type: :object,
      properties: %{
        user_id: %Schema{type: :string, format: :uuid, description: "The member to ban"},
        reason: %Schema{type: :string, nullable: true}
      },
      required: [:user_id]
    })
  end

  defmodule InstanceBanParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InstanceBanParams",
      description:
        "An instance-wide ban is keyed on the email itself (SPEC §11) — " <>
          "unlike the community ban's user_id — so it can also block " <>
          "addresses without an account. 422 details land on `email` " <>
          "when the address is already banned.",
      type: :object,
      properties: %{
        email: %Schema{type: :string, format: :email, description: "The email to ban"},
        reason: %Schema{type: :string, nullable: true}
      },
      required: [:email]
    })
  end

  defmodule AuditEvent do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AuditEvent",
      description: "One append-only audit entry (issue #183, SPEC §11).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        action: %Schema{type: :string, example: "member.banned"},
        summary: %Schema{type: :string},
        metadata: %Schema{type: :object},
        inserted_at: %Schema{type: :string, format: :"date-time"},
        actor: %Schema{
          type: :object,
          nullable: true,
          description: "The acting user, or null for a system action.",
          properties: %{
            id: %Schema{type: :string, format: :uuid},
            display_name: %Schema{type: :string}
          }
        }
      },
      required: [:id, :action, :summary, :inserted_at]
    })
  end

  defmodule InstanceSettings do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InstanceSettings",
      description: "Operator-editable instance settings (issue #183, SPEC §13).",
      type: :object,
      properties: %{
        instance_name: %Schema{type: :string, nullable: true},
        default_locale: %Schema{type: :string, enum: ["en", "da"]},
        community_creation_policy: %Schema{
          type: :string,
          enum: ["operators_only", "any_user"]
        },
        storage_policy: %Schema{type: :string, enum: ["unmetered", "quota"]},
        content_minimized_emails: %Schema{type: :boolean}
      },
      required: [
        :default_locale,
        :community_creation_policy,
        :storage_policy,
        :content_minimized_emails
      ]
    })
  end

  defmodule InstanceSettingsParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "InstanceSettingsParams",
      description: "Instance-settings changes (issue #183). All fields optional.",
      type: :object,
      properties: %{
        instance_name: %Schema{type: :string, nullable: true},
        default_locale: %Schema{type: :string, enum: ["en", "da"]},
        community_creation_policy: %Schema{type: :string, enum: ["operators_only", "any_user"]},
        storage_policy: %Schema{type: :string, enum: ["unmetered", "quota"]},
        content_minimized_emails: %Schema{type: :boolean}
      }
    })
  end

  defmodule StatusOnly do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "StatusOnly",
      description: "A bare status acknowledgement, e.g. {\"status\": \"unbanned\"}.",
      type: :object,
      properties: %{status: %Schema{type: :string}},
      required: [:status]
    })
  end

  defmodule UserRef do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "UserRef",
      description: "A person reference: id and display name. Null when not resolved.",
      type: :object,
      nullable: true,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        display_name: %Schema{type: :string}
      },
      required: [:id, :display_name]
    })
  end

  defmodule EventSeries do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EventSeries",
      description: "A recurring event series' rule (ADR 0019): its cadence and last date.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        frequency: %Schema{type: :string, enum: ["weekly", "biweekly", "monthly"]},
        until: %Schema{type: :string, format: :date, description: "Last date the series may run"}
      },
      required: [:id, :group_id, :frequency, :until]
    })
  end

  defmodule EventSeriesDetail do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "EventSeriesDetail",
      description:
        "A recurring series' organizer view (SPEC §6, ADR 0019): the series rule, " <>
          "every occurrence (with RSVP counts and cancel state), and the attendance " <>
          "matrix — group members by upcoming occurrence, each cell the member's RSVP. " <>
          "Members only; guest RSVPs count toward an occurrence's rsvp_counts but are " <>
          "never matrix rows. Organizer-only (the series' creator or a group moderator).",
      type: :object,
      properties: %{
        series: EventSeries,
        occurrences: %Schema{
          type: :array,
          description: "Every occurrence, soonest first — including past and cancelled ones",
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              starts_at: %Schema{type: :string, format: :"date-time"},
              ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
              all_day: %Schema{type: :boolean},
              cancelled: %Schema{type: :boolean},
              rsvp_counts: %Schema{
                type: :object,
                properties: %{
                  yes: %Schema{type: :integer},
                  maybe: %Schema{type: :integer},
                  no: %Schema{type: :integer},
                  waitlisted: %Schema{type: :integer}
                },
                required: [:yes, :maybe, :no, :waitlisted]
              }
            },
            required: [:id, :starts_at, :all_day, :cancelled, :rsvp_counts]
          }
        },
        attendance: %Schema{
          type: :object,
          description:
            "The matrix: upcoming non-cancelled occurrences as columns, members as rows",
          properties: %{
            occurrences: %Schema{
              type: :array,
              description:
                "The matrix columns — upcoming, non-cancelled occurrences, soonest first",
              items: %Schema{
                type: :object,
                properties: %{
                  id: %Schema{type: :string, format: :uuid},
                  starts_at: %Schema{type: :string, format: :"date-time"}
                },
                required: [:id, :starts_at]
              }
            },
            rows: %Schema{
              type: :array,
              description: "One row per group member",
              items: %Schema{
                type: :object,
                properties: %{
                  member: UserRef,
                  statuses: %Schema{
                    type: :array,
                    description:
                      "The member's RSVP per matrix occurrence, aligned by index to " <>
                        "attendance.occurrences; null where they haven't answered",
                    items: %Schema{
                      type: :string,
                      enum: ["yes", "no", "maybe", "waitlisted"],
                      nullable: true
                    }
                  }
                },
                required: [:member, :statuses]
              }
            }
          },
          required: [:occurrences, :rows]
        }
      },
      required: [:series, :occurrences, :attendance]
    })
  end

  defmodule AvailabilityPoll do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "AvailabilityPoll",
      description:
        "A date-finding poll (issue #39): candidate dates members answer " <>
          "per date. Closing can convert the winning date into an event. " <>
          "Feature-gated per group (`availability`).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        closed: %Schema{type: :boolean},
        converted_event_id: %Schema{
          type: :string,
          format: :uuid,
          nullable: true,
          description: "The event a converted poll produced (ADR 0019)"
        },
        created_at: %Schema{type: :string, format: :"date-time"},
        created_by: UserRef,
        options: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              id: %Schema{type: :string, format: :uuid},
              starts_at: %Schema{type: :string, format: :"date-time"},
              position: %Schema{type: :integer},
              responses: %Schema{
                type: :array,
                items: %Schema{
                  type: :object,
                  properties: %{
                    user: UserRef,
                    answer: %Schema{type: :string, enum: ["yes", "if_needed", "no"]}
                  },
                  required: [:answer]
                }
              },
              my_answer: %Schema{
                type: :string,
                enum: ["yes", "if_needed", "no"],
                nullable: true,
                description: "The caller's own answer for this date, if any"
              }
            },
            required: [:id, :starts_at, :position, :responses]
          }
        },
        viewer_can: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["respond", "manage"]},
          description:
            "Advisory actions the caller may take (issue #199) — `respond` " <>
              "while open, `manage` (close/convert) for creator or moderator. " <>
              "Empty when the viewer's rights weren't resolved."
        }
      },
      required: [:id, :group_id, :title, :closed, :created_at, :options, :viewer_can]
    })
  end

  defmodule Assignment do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Assignment",
      description:
        "A lightweight group task (issue #17): open / claimed / done, " <>
          "several claimants allowed. Feature-gated per group " <>
          "(`assignments`). `comments`/`comment_count` are populated on " <>
          "detail, empty on the list.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        notes_markdown: %Schema{type: :string, nullable: true},
        due_at: %Schema{type: :string, format: :"date-time", nullable: true},
        completed: %Schema{type: :boolean},
        completed_at: %Schema{type: :string, format: :"date-time", nullable: true},
        completed_by: UserRef,
        created_at: %Schema{type: :string, format: :"date-time"},
        created_by: UserRef,
        claims: %Schema{
          type: :array,
          items: UserRef,
          description: "Everyone currently holding a claim"
        },
        claimed_by_me: %Schema{type: :boolean},
        comment_count: %Schema{type: :integer, nullable: true},
        comments: %Schema{type: :array, items: Comment},
        viewer_can: %Schema{
          type: :array,
          items: %Schema{
            type: :string,
            enum: ["claim", "complete", "reopen", "comment", "manage"]
          },
          description:
            "Advisory actions the caller may take (issue #199) — " <>
              "`claim`/`complete` while open, `reopen` while done, `comment`, " <>
              "`manage` (edit/delete) for creator or moderator. Empty when the " <>
              "viewer's rights weren't resolved."
        }
      },
      required: [
        :id,
        :group_id,
        :title,
        :completed,
        :created_at,
        :claims,
        :claimed_by_me,
        :comments,
        :viewer_can
      ]
    })
  end

  defmodule Decision do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "Decision",
      description:
        "A decisions-register entry (issue #43): the motion, its linked " <>
          "feed post (`post_id`, carrying the For/Against/Abstain vote), and " <>
          "the recorded outcome. Feature-gated per group (`decisions`).",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        group_id: %Schema{type: :string, format: :uuid},
        post_id: %Schema{type: :string, format: :uuid},
        title: %Schema{type: :string},
        outcome: %Schema{
          type: :string,
          enum: ["adopted", "rejected", "noted"],
          nullable: true,
          description: "Null until an outcome is recorded"
        },
        outcome_note: %Schema{type: :string, nullable: true},
        decided: %Schema{type: :boolean},
        decided_at: %Schema{type: :string, format: :"date-time", nullable: true},
        decided_by: UserRef,
        created_at: %Schema{type: :string, format: :"date-time"},
        viewer_can: %Schema{
          type: :array,
          items: %Schema{type: :string, enum: ["record_outcome"]},
          description:
            "Advisory actions the caller may take (issue #199) — " <>
              "`record_outcome` for the motion's proposer or a moderator."
        }
      },
      required: [:id, :group_id, :post_id, :title, :decided, :created_at, :viewer_can]
    })
  end

  defmodule SearchResults do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SearchResults",
      description:
        "Global search hits (SPEC §16), already narrowed to what the " <>
          "viewer may see. Up to ten per section, best matches first.",
      type: :object,
      properties: %{
        posts: %Schema{type: :array, items: Post},
        comments: %Schema{type: :array, items: Comment},
        events: %Schema{type: :array, items: Event},
        files: %Schema{type: :array, items: LibraryFile}
      },
      required: [:posts, :comments, :events, :files]
    })
  end

  defmodule GuestConfirmation do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GuestConfirmation",
      description:
        "A confirmed guest action (issue #185): the guest's name (when " <>
          "the flow knows it) and the client-relative path the PWA lands " <>
          "on next — the API twin of the web confirm redirect.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            guest_name: %Schema{type: :string, nullable: true},
            redirect_path: %Schema{type: :string}
          },
          required: [:redirect_path, :guest_name]
        }
      },
      required: [:data]
    })
  end

  defmodule GuestManageState do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "GuestManageState",
      description:
        "Everything behind a guest's management link (issue #185): their " <>
          "identity, RSVPs, signup claims, comments, and newsletter " <>
          "subscriptions. Returned by the manage read and by every manage " <>
          "mutation (the refreshed inventory).",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            identity: %Schema{
              type: :object,
              properties: %{
                display_name: %Schema{type: :string},
                email: %Schema{type: :string, format: :email}
              },
              required: [:display_name, :email]
            },
            rsvps: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  event_id: %Schema{type: :string, format: :uuid},
                  event_title: %Schema{type: :string},
                  status: %Schema{type: :string, enum: ["yes", "no", "maybe", "waitlisted"]}
                },
                required: [:event_id, :event_title, :status]
              }
            },
            claims: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  claim_id: %Schema{type: :string, format: :uuid},
                  slot_title: %Schema{type: :string},
                  event_title: %Schema{type: :string}
                },
                required: [:claim_id, :slot_title, :event_title]
              }
            },
            comments: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  group_name: %Schema{type: :string},
                  body_markdown: %Schema{type: :string},
                  pending_approval: %Schema{type: :boolean},
                  removed: %Schema{type: :boolean}
                },
                required: [:group_name, :body_markdown, :pending_approval, :removed]
              }
            },
            subscriptions: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                properties: %{
                  subscription_id: %Schema{type: :string, format: :uuid},
                  community_name: %Schema{type: :string},
                  group_name: %Schema{type: :string},
                  cadence: %Schema{type: :string, enum: ["per_post", "daily", "weekly"]}
                },
                required: [:subscription_id, :community_name, :group_name, :cadence]
              }
            }
          },
          required: [:identity, :rsvps, :claims, :comments, :subscriptions]
        }
      },
      required: [:data]
    })
  end

  defmodule LegalPage do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LegalPage",
      description:
        "A public legal page (issue #185, SPEC §13): the operator's text " <>
          "or the built-in template, as authored markdown and rendered HTML.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            key: %Schema{type: :string, enum: ["privacy", "imprint"]},
            title: %Schema{type: :string},
            content_markdown: %Schema{type: :string},
            content_html: %Schema{type: :string},
            published: %Schema{
              type: :boolean,
              description: "False while the built-in template still shows"
            }
          },
          required: [:key, :title, :content_markdown, :content_html, :published]
        }
      },
      required: [:data]
    })
  end

  defmodule LegalPageParams do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "LegalPageParams",
      description:
        "A legal-page edit (issue #259, SPEC §13): the authored markdown " <>
          "that replaces the built-in template. Instance operators only.",
      type: :object,
      properties: %{
        content_markdown: %Schema{type: :string, minLength: 1, maxLength: 100_000}
      },
      required: [:content_markdown]
    })
  end

  defmodule SetupStatus do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SetupStatus",
      description: "Whether first-run setup has completed (issue #185, SPEC §13).",
      type: :object,
      properties: %{setup_completed: %Schema{type: :boolean}},
      required: [:setup_completed]
    })
  end

  defmodule SetupResult do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SetupResult",
      description:
        "The completed instance (issue #185): the first community and " <>
          "group, the shareable invite link, and whether the operator's " <>
          "first magic link (the live SMTP test) went out.",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            community_slug: %Schema{type: :string},
            group_slug: %Schema{type: :string},
            invite_token: %Schema{type: :string},
            invite_url: %Schema{type: :string},
            magic_link_sent: %Schema{type: :boolean}
          },
          required: [:community_slug, :group_slug, :invite_token, :invite_url, :magic_link_sent]
        }
      },
      required: [:data]
    })
  end
end
