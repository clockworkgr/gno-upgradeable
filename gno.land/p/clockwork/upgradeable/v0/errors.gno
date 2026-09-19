package upgradeable

import "errors"

var (
	// ErrNoAuthority is raised when a Proxy is built, or handed, a nil
	// authority. There is no "nobody" authority: to end upgradeability,
	// Freeze it.
	ErrNoAuthority = errors.New("upgradeable: an authority is required")

	// ErrUnauthorized is raised when the caller is not the authority.
	ErrUnauthorized = errors.New("upgradeable: caller is not the authority")

	// ErrStaleRealm is raised when the threaded realm value is not the
	// caller's live cur -- a stashed or replayed capture.
	ErrStaleRealm = errors.New("upgradeable: realm value is not the caller's live cur")

	// ErrFrozen is raised by every mutating method once Freeze has run.
	ErrFrozen = errors.New("upgradeable: proxy is frozen")

	// ErrNoImpl is raised when the proxy is asked for an implementation it
	// does not have yet.
	ErrNoImpl = errors.New("upgradeable: no implementation is live")

	// ErrNotNested is raised when a candidate registers from a realm that is
	// not under the proxy realm's own path. See New and NewOpen.
	ErrNotNested = errors.New("upgradeable: candidate realm is not nested under this one")

	// ErrNotARealm is raised when a candidate registers from a user call
	// rather than from a deployed realm, so there is no path to record.
	ErrNotARealm = errors.New("upgradeable: only a deployed realm can register a candidate")

	// ErrNilImpl is raised when the registered implementation is nil.
	ErrNilImpl = errors.New("upgradeable: implementation is nil")

	// ErrUnknownPath is raised when accepting or withdrawing a path that has
	// no candidate registered against it.
	ErrUnknownPath = errors.New("upgradeable: no candidate registered at that path")

	// ErrNoHistory is raised by Rollback when nothing has been replaced yet.
	ErrNoHistory = errors.New("upgradeable: no previous release to roll back to")

	// ErrBadAddress is raised when an authority is built from an invalid
	// address.
	ErrBadAddress = errors.New("upgradeable: invalid address")

	// ErrBadRealmPath is raised when an authority is built from a realm path
	// that is blank or carries surrounding whitespace. Both are silent
	// lockouts: a blank entry matches every user call, and a padded one
	// matches no caller at all.
	ErrBadRealmPath = errors.New("upgradeable: authority realm paths must be non-blank and unpadded")
)
