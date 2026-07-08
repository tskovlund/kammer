defmodule KammerWeb.PostPermissions do
  @moduledoc """
  The permission map `<.post_card>` expects, computed once so the group
  feed and the aggregated community home feed can't drift on which
  actions a post shows.
  """

  alias Kammer.Accounts.User
  alias Kammer.Authorization
  alias Kammer.Feed.Post
  alias Kammer.Groups.Group

  @spec for_post(Post.t(), Group.t(), Authorization.relationship(), User.t() | nil) :: map()
  def for_post(post, group, relationship, current_user) do
    %{
      edit: Authorization.can_edit_post?(current_user, post, group, relationship),
      soft_delete: Authorization.can_soft_delete_post?(current_user, post, group, relationship),
      hard_delete: Authorization.can_hard_delete_post?(current_user, post, group, relationship),
      pin: Authorization.can_pin_post?(current_user, post, group, relationship),
      lock_comments:
        Authorization.can_lock_post_comments?(current_user, post, group, relationship),
      view_acknowledgments:
        current_user != nil and
          Authorization.can_view_acknowledgments?(current_user, post, group, relationship),
      approve: Authorization.can?(current_user, :moderate_group, group, relationship),
      comment: Authorization.can?(current_user, :comment_in_group, group, relationship),
      react: Authorization.can_react?(current_user, group, relationship)
    }
  end
end
