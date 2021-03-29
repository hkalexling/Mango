const loadPlugin = id => {
	localStorage.setItem('plugin', id);
	const url = `${location.protocol}//${location.host}${location.pathname}`;
	const newURL = `${url}?${$.param({
			plugin: id
		})}`;
	window.location.href = newURL;
};

$(() => {
	var storedID = localStorage.getItem('plugin');
	if (storedID && storedID !== pid) {
		loadPlugin(storedID);
	} else {
		$('#controls').removeAttr('hidden');
	}

	$('#search-input').keypress(event => {
		if (event.which === 13) {
			search();
		}
	});
	$('#plugin-select').val(pid);
	$('#plugin-select').change(() => {
		const id = $('#plugin-select').val();
		loadPlugin(id);
	});
});

let mangaTitle = "";
let searching = false;
const search = () => {
	if (searching)
		return;

	const query = $.param({
		query: $('#search-input').val(),
		plugin: pid
	});
	$.ajax({
			type: 'GET',
			url: `${base_url}api/admin/plugin/list?${query}`,
			contentType: "application/json",
			dataType: 'json'
		})
		.done(data => {
			console.log(data);
			if (data.error) {
				alert('danger', `Search failed. Error: ${data.error}`);
				return;
			}
			mangaTitle = data.title;
			$('#title-text').text(data.title);
			buildTable(data.chapters);
		})
		.fail((jqXHR, status) => {
			alert('danger', `Search failed. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
		})
		.always(() => {});
};

const buildTable = (chapters) => {
	$('#table').attr('hidden', '');
	$('table').empty();

	const keys = Object.keys(chapters[0]).map(k => `<th>${k}</th>`).join('');
	const thead = `<thead><tr>${keys}</tr></thead>`;
	$('table').append(thead);

	const rows = chapters.map(ch => {
		const tds = Object.values(ch).map(v => `<td>${v}</td>`).join('');
		return `<tr data-id="${ch.id}" data-title="${ch.title}">${tds}</tr>`;
	});
	const tbody = `<tbody id="selectable">${rows}</tbody>`;
	$('table').append(tbody);

	$('#selectable').selectable({
		filter: 'tr'
	});

	$('#table table').tablesorter();
	$('#table').removeAttr('hidden');
};

const selectAll = () => {
	$('tbody > tr').each((i, e) => {
		$(e).addClass('ui-selected');
	});
};

const unselect = () => {
	$('tbody > tr').each((i, e) => {
		$(e).removeClass('ui-selected');
	});
};

const download = () => {
	const selected = $('tbody > tr.ui-selected');
	if (selected.length === 0) return;
	UIkit.modal.confirm(`Download ${selected.length} selected chapters?`).then(() => {
		$('#download-btn').attr('hidden', '');
		$('#download-spinner').removeAttr('hidden');
		const chapters = selected.map((i, e) => {
			return {
				id: $(e).attr('data-id'),
				title: $(e).attr('data-title')
			}
		}).get();
		console.log(chapters);
		$.ajax({
				type: 'POST',
				url: base_url + 'api/admin/plugin/download',
				data: JSON.stringify({
					plugin: pid,
					chapters: chapters,
					title: mangaTitle
				}),
				contentType: "application/json",
				dataType: 'json'
			})
			.done(data => {
				console.log(data);
				if (data.error) {
					alert('danger', `Failed to add chapters to the download queue. Error: ${data.error}`);
					return;
				}
				const successCount = parseInt(data.success);
				const failCount = parseInt(data.fail);
				alert('success', `${successCount} of ${successCount + failCount} chapters added to the download queue. You can view and manage your download queue on the <a href="${base_url}admin/downloads">download manager page</a>.`);
			})
			.fail((jqXHR, status) => {
				alert('danger', `Failed to add chapters to the download queue. Error: [${jqXHR.status}] ${jqXHR.statusText}`);
			})
			.always(() => {
				$('#download-spinner').attr('hidden', '');
				$('#download-btn').removeAttr('hidden');
			});
	});
};
