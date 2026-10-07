// SAFE TEST PROFILE: repository/GPG/package resolution only.
// It does not define storage and it does not start installation.
// Load it with "agama config generate ... | agama config load".

{
  product: {
    id: "Slowroll",
  },

  software: {
    // Replace product preselected patterns for this test only.
    patterns: [],

    // criscore1 requires the matching criscore2 build.
    packages: [
      "criscore1",
    ],

    extraRepositories: [
      {
        alias: "home_krism",
        name: "home:krism - openSUSE Slowroll",
        url: "https://download.opensuse.org/repositories/home:/krism/openSUSE_Slowroll/",
        priority: 90,
        gpgFingerprints: [
          "8528 3DD3 E1AF A9EA 668E 2065 3505 E29C 78A0 0759",
        ],
      },
    ],

    onlyRequired: true,
  },
}
