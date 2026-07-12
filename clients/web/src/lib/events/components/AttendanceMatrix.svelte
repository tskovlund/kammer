<script lang="ts">
	import { formatDate } from '$lib/i18n/datetime.js';
	import { i18n, t } from '$lib/i18n/i18n.svelte.js';
	import type { EventSeriesDetail } from '$lib/events/types.js';

	interface Props {
		/** The organizer matrix: upcoming occurrences as columns, members as rows. */
		attendance: EventSeriesDetail['attendance'];
	}
	let { attendance }: Props = $props();

	type Status = EventSeriesDetail['attendance']['rows'][number]['statuses'][number];

	const glyphs: Record<'yes' | 'maybe' | 'no', string> = { yes: '✅', maybe: '❔', no: '❌' };

	function glyph(status: Status): string {
		return status === 'yes' || status === 'maybe' || status === 'no' ? glyphs[status] : '—';
	}

	// The cell's accessible name is the RSVP word; the glyph is decorative.
	function statusLabel(status: Status): string {
		return t(`events.series.rsvp.${status ?? 'none'}`);
	}
</script>

{#if attendance.occurrences.length === 0}
	<p class="text-sm text-ink-muted">{t('events.series.attendanceEmpty')}</p>
{:else}
	<div class="overflow-x-auto">
		<table class="w-full border-collapse text-sm">
			<thead>
				<tr class="border-b border-line text-left">
					<th scope="col" class="p-2 font-medium text-ink-muted">{t('events.series.member')}</th>
					{#each attendance.occurrences as occurrence (occurrence.id)}
						<th scope="col" class="p-2 font-medium whitespace-nowrap text-ink-muted">
							{formatDate(occurrence.starts_at, i18n.locale)}
						</th>
					{/each}
				</tr>
			</thead>
			<tbody>
				{#each attendance.rows as row (row.member?.id)}
					<tr class="border-b border-line/60">
						<th scope="row" class="p-2 text-left font-normal whitespace-nowrap text-ink">
							{row.member?.display_name}
						</th>
						{#each row.statuses as status, i (attendance.occurrences[i].id)}
							<td class="p-2 text-center">
								<span aria-label={statusLabel(status)} title={statusLabel(status)}>
									{glyph(status)}
								</span>
							</td>
						{/each}
					</tr>
				{/each}
			</tbody>
		</table>
	</div>
{/if}
