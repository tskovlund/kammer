<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import { ApiError } from '$lib/api/errors.js';
	import { t } from '$lib/i18n/i18n.svelte.js';
	import { revokeAndRemoveInstance } from '$lib/instances/api.js';
	import { instances } from '$lib/instances/instances.svelte.js';
	import { isStepUpRequired } from '$lib/instances/stepup.js';
	import { deleteAccount, fetchAccountExportUrl } from '$lib/people/api.js';
	import Button from '$lib/ui/Button.svelte';
	import EmptyState from '$lib/ui/EmptyState.svelte';
	import Input from '$lib/ui/Input.svelte';
	import StepUpModal from '$lib/ui/StepUpModal.svelte';

	const instance = $derived(
		instances.list.find((candidate) => candidate.id === page.params.instance)
	);

	let exporting = $state(false);
	let exportError = $state<string | null>(null);

	// The delete flow (issue #258): the danger button reveals a typed
	// confirmation — the account's own email, which the server verifies
	// again (422 on mismatch) before erasing anything.
	let confirmingDelete = $state(false);
	let typedEmail = $state('');
	let deleting = $state(false);
	let deleteError = $state<string | null>(null);

	const emailMatches = $derived(
		instance !== undefined && typedEmail.trim().toLowerCase() === instance.user.email.toLowerCase()
	);

	// Both flows are step-up-gated (issue #323, ADR 0029): a 401
	// step_up_required opens the confirmation modal, which retries the
	// original action afterwards.
	let stepUpRetry = $state<(() => Promise<void>) | null>(null);

	async function doExport(): Promise<void> {
		// The instance can vanish mid-flow (removed from another tab while
		// the step-up modal is open); a silent return here would read as
		// success, so fail like any other error instead.
		if (!instance) throw new ApiError('not_found', 'Account is gone from this device.', null);
		const url = await fetchAccountExportUrl(instance);
		// Same anchor dance as the search page's attachment download.
		const anchor = document.createElement('a');
		anchor.href = url;
		anchor.download = `kammer-export-${new Date().toISOString().slice(0, 10)}.zip`;
		anchor.rel = 'noopener';
		document.body.appendChild(anchor);
		anchor.click();
		anchor.remove();
		URL.revokeObjectURL(url);
	}

	async function exportData(): Promise<void> {
		if (!instance) return;
		exporting = true;
		exportError = null;
		try {
			await doExport();
		} catch (error) {
			if (isStepUpRequired(error)) {
				stepUpRetry = () => doExport();
			} else {
				exportError = t('account.export.error');
			}
		} finally {
			exporting = false;
		}
	}

	async function doDelete(typed: string): Promise<void> {
		// Same vanished-instance stance as doExport: fail, don't fake success.
		if (!instance) throw new ApiError('not_found', 'Account is gone from this device.', null);
		await deleteAccount(instance, typed);
		// The account is gone server-side; drop the instance locally the
		// same way sign-out does (best-effort revoke of the now-dead
		// token, push unsubscribe, snapshot clear).
		await revokeAndRemoveInstance(instance.id);
		instances.refresh();
		// The (app) layout's guard redirects to /welcome if this was the
		// last account.
		await goto(resolve('/you'));
	}

	async function confirmDelete(submitEvent: SubmitEvent): Promise<void> {
		submitEvent.preventDefault();
		if (!instance) return;
		deleting = true;
		deleteError = null;
		const typed = typedEmail.trim();
		try {
			await doDelete(typed);
		} catch (error) {
			if (isStepUpRequired(error)) {
				stepUpRetry = () => doDelete(typed);
			} else {
				deleteError =
					error instanceof ApiError && error.kind === 'validation'
						? t('account.delete.error.mismatch')
						: t('account.delete.error.generic');
			}
			deleting = false;
		}
	}

	const backHref = resolve('/you');
</script>

<svelte:head>
	<title>{t('account.title')} · {t('app.name')}</title>
</svelte:head>

{#if !instance}
	<EmptyState title={t('feed.instanceMissing.title')} body={t('feed.instanceMissing.body')} />
{:else}
	<header class="mb-6 flex flex-col gap-3">
		<!-- eslint-disable-next-line svelte/no-navigation-without-resolve -->
		<a href={backHref} class="flex items-center gap-1 text-sm text-ink-muted hover:text-ink">
			<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" class="size-4">
				<path stroke-linecap="round" stroke-linejoin="round" d="M15.75 19.5L8.25 12l7.5-7.5" />
			</svg>
			{t('nav.you')}
		</a>
		<div>
			<h1 class="text-xl font-semibold tracking-tight text-ink">{t('account.title')}</h1>
			<p class="mt-0.5 text-sm text-ink-muted">
				{instances.solo
					? t('account.descriptionSolo')
					: t('account.description', { name: instance.instanceName })}
			</p>
		</div>
	</header>

	<section aria-labelledby="account-export-heading">
		<h2 id="account-export-heading" class="text-sm font-medium text-ink">
			{t('account.export.title')}
		</h2>
		<p class="mt-1 text-sm text-ink-muted">
			{instances.solo
				? t('account.export.descriptionSolo')
				: t('account.export.description', { name: instance.instanceName })}
		</p>
		{#if exportError}
			<div
				class="mt-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{exportError}
			</div>
		{/if}
		<div class="mt-3">
			<Button variant="secondary" disabled={exporting} onclick={exportData} id="account-export">
				{t('account.export.button')}
			</Button>
		</div>
	</section>

	<section class="mt-10" aria-labelledby="account-delete-heading">
		<h2 id="account-delete-heading" class="text-sm font-medium text-danger">
			{t('account.delete.title')}
		</h2>
		<p class="mt-1 text-sm text-ink-muted">
			{instances.solo
				? t('account.delete.descriptionSolo')
				: t('account.delete.description', { name: instance.instanceName })}
		</p>

		{#if deleteError}
			<div
				class="mt-3 rounded-lg border border-danger/30 bg-danger/5 px-3 py-2 text-sm text-danger"
				role="alert"
			>
				{deleteError}
			</div>
		{/if}

		{#if confirmingDelete}
			<form
				class="mt-3 flex flex-col gap-3 rounded-lg border border-danger/30 p-4"
				onsubmit={confirmDelete}
				id="account-delete-form"
			>
				<Input
					id="account-delete-input"
					type="email"
					label={t('account.delete.confirmLabel', { email: instance.user.email })}
					bind:value={typedEmail}
				/>
				<div class="flex items-center gap-3">
					<Button
						type="submit"
						variant="danger"
						disabled={deleting || !emailMatches}
						id="account-delete-confirm"
					>
						{t('account.delete.confirmButton')}
					</Button>
					<Button
						variant="ghost"
						disabled={deleting}
						onclick={() => {
							confirmingDelete = false;
							typedEmail = '';
							deleteError = null;
						}}
					>
						{t('common.cancel')}
					</Button>
				</div>
			</form>
		{:else}
			<div class="mt-3">
				<Button variant="danger" onclick={() => (confirmingDelete = true)} id="account-delete">
					{t('account.delete.button')}
				</Button>
			</div>
		{/if}
	</section>

	{#if stepUpRetry}
		<StepUpModal
			{instance}
			retry={stepUpRetry}
			onsuccess={() => (stepUpRetry = null)}
			oncancel={() => (stepUpRetry = null)}
		/>
	{/if}
{/if}
