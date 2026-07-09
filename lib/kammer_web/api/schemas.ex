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
        description: %Schema{type: :string, nullable: true}
      },
      required: [:id, :name, :slug]
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
        features: %Schema{type: :array, items: %Schema{type: :string}},
        sealed: %Schema{type: :boolean},
        archived: %Schema{type: :boolean}
      },
      required: [:id, :name, :slug, :visibility, :features, :sealed, :archived]
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
        :attachments
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
        title: %Schema{type: :string},
        description_markdown: %Schema{type: :string, nullable: true},
        starts_at: %Schema{type: :string, format: :"date-time"},
        ends_at: %Schema{type: :string, format: :"date-time", nullable: true},
        all_day: %Schema{type: :boolean},
        timezone: %Schema{type: :string},
        location_name: %Schema{type: :string, nullable: true},
        location_url: %Schema{type: :string, nullable: true},
        rsvp_counts: %Schema{
          type: :object,
          properties: %{
            yes: %Schema{type: :integer},
            maybe: %Schema{type: :integer},
            no: %Schema{type: :integer}
          },
          required: [:yes, :maybe, :no]
        },
        my_rsvp: %Schema{type: :string, enum: ["yes", "no", "maybe"], nullable: true},
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
        }
      },
      required: [:id, :group_id, :title, :starts_at, :all_day, :timezone, :rsvp_counts]
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
            "event_reminder"
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
        default_locale: %Schema{type: :string},
        features: %Schema{
          type: :object,
          properties: %{
            guest_rsvp: %Schema{type: :boolean},
            web_push: %Schema{type: :boolean},
            registration: %Schema{type: :string, enum: ["open", "web_only"]}
          },
          required: [:guest_rsvp, :web_push, :registration]
        }
      },
      required: [:instance_name, :version, :api_versions, :default_locale, :features]
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
end
