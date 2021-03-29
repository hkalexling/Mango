const component = () => {
	return {
		available: undefined,
		subscriptions: [],

		init() {
			$.getJSON(`${base_url}api/admin/mangadex/expires`)
				.done((data) => {
					if (data.error) {
						alert('danger', 'Failed to check MangaDex integration status. Error: ' + data.error);
						return;
					}
					this.available = Boolean(data.expires && data.expires > Math.floor(Date.now() / 1000));

					if (this.available) this.getSubscriptions();
				})
				.fail((jqXHR, status) => {
					alert('danger', `Failed to check MangaDex integration status. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
				})
		},

		getSubscriptions() {
			$.getJSON(`${base_url}api/admin/mangadex/subscriptions`)
				.done(data => {
					if (data.error) {
						alert('danger', 'Failed to get subscriptions. Error: ' + data.error);
						return;
					}
					this.subscriptions = data.subscriptions;
				})
				.fail((jqXHR, status) => {
					alert('danger', `Failed to get subscriptions. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
				})
		},

		rm(event) {
			const id = event.currentTarget.parentNode.getAttribute('data-id');
			$.ajax({
					type: 'DELETE',
					url: `${base_url}api/admin/mangadex/subscriptions/${id}`,
					contentType: 'application/json'
				})
				.done(data => {
					if (data.error) {
						alert('danger', `Failed to delete subscription. Error: ${data.error}`);
					}
					this.getSubscriptions();
				})
				.fail((jqXHR, status) => {
					alert('danger', `Failed to delete subscription. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
				});
		},

		check(event) {
			const id = event.currentTarget.parentNode.getAttribute('data-id');
			$.ajax({
					type: 'POST',
					url: `${base_url}api/admin/mangadex/subscriptions/check/${id}`,
					contentType: 'application/json'
				})
				.done(data => {
					if (data.error) {
						alert('danger', `Failed to check subscription. Error: ${data.error}`);
						return;
					}
					alert('success', 'Mango is now checking the subscription for updates. This might take a while, but you can safely leave the page.');
				})
				.fail((jqXHR, status) => {
					alert('danger', `Failed to check subscription. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
				});
		},

		formatRange(min, max) {
			if (!isNaN(min) && isNaN(max)) return `≥ ${min}`;
			if (isNaN(min) && !isNaN(max)) return `≤ ${max}`;
			if (isNaN(min) && isNaN(max)) return 'All';

			if (min === max) return `= ${min}`;
			return `${min} - ${max}`;
		}
	};
};
