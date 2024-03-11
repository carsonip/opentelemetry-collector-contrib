package elasticsearchexporter

import (
	"context"
	"github.com/elastic/go-docappender"
)

type Request struct {
	bulkIndexer *esBulkIndexerCurrent
	items       []docappender.BulkIndexerItem
}

func NewRequest(bulkIndexer *esBulkIndexerCurrent) *Request {
	return &Request{bulkIndexer: bulkIndexer}
}

func (r *Request) Export(ctx context.Context) error {
	for _, item := range r.items {
		if err := r.bulkIndexer.Add(item); err != nil {
			return err // FIXME
		}
	}
	_, err := r.bulkIndexer.Flush(ctx)
	return err
}

func (r *Request) ItemsCount() int {
	return len(r.items)
}
