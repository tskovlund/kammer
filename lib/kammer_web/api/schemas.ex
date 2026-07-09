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
      required: [:id, :name, :slug, :viewer_can]
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
        :viewer_can
      ]
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
        :rsvp_counts,
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
        min_client_version: %Schema{
          type: :string,
          nullable: true,
          description:
            "Advisory SemVer floor for the native-app handshake (#203): " <>
              "clients below it should fence themselves — the server does " <>
              "not reject them. Null means any client is fine."
        },
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
      required: [
        :instance_name,
        :version,
        :api_versions,
        :min_client_version,
        :default_locale,
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
          "visibilities included because it is theirs. Email changes stay " <>
          "on the web flow.",
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
end
